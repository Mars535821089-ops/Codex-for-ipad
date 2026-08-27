use super::thread_directory::ThreadRecord;
use crate::CoreError;
use serde::de::{DeserializeOwned, Error as SerdeError};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};

const OFFICIAL_NOTIFICATION_FIELD: &str = "__officialThreadSettingsNotification";
const MAX_SETTINGS_PATCH_BYTES: usize = 64 * 1024;
const OFFICIAL_OPENAI_DEFAULT_MODEL: &str = "gpt-5.6-sol";
const OFFICIAL_OPENAI_DEFAULT_EFFORT: &str = "low";
const SERVICE_TIER_DEFAULT: &str = "default";

pub(super) fn prepare_rpc_command(
    known_thread_ids: &HashSet<String>,
    records: &HashMap<String, ThreadRecord>,
    stored_settings: &HashMap<String, Value>,
    params: &Value,
) -> Result<Option<Vec<u8>>, CoreError> {
    let typed = parse_canonical_patch(known_thread_ids, params)?;
    if !typed.has_effective_update() {
        return Ok(None);
    }

    let record = records
        .get(&typed.thread_id)
        .ok_or(CoreError::InvalidArgument)?;
    let existing = stored_settings.get(&typed.thread_id);
    let effective = ThreadSettings::resolve(record, existing, typed.clone())?;
    let effective_value = settings_value(&effective)?;
    if is_current_effective(record, existing, &typed.thread_id, &effective_value)? {
        return Ok(None);
    }

    let mut command = serde_json::to_value(&typed)
        .map_err(|_| CoreError::InvalidJson)?
        .as_object()
        .cloned()
        .ok_or(CoreError::InvalidJson)?;
    command.insert(
        "kind".to_owned(),
        Value::String("thread.settings-update".to_owned()),
    );
    command.insert(OFFICIAL_NOTIFICATION_FIELD.to_owned(), Value::Bool(true));
    serde_json::to_vec(&command)
        .map(Some)
        .map_err(|_| CoreError::InvalidJson)
}

pub(super) fn prepare_initial_settings(
    record: &ThreadRecord,
    thread_id: &str,
    params: &Value,
) -> Result<Value, CoreError> {
    let source = params.as_object().ok_or(CoreError::InvalidArgument)?;
    let config = match source.get("config") {
        None | Some(Value::Null) => None,
        Some(Value::Object(config)) => Some(config),
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    let typed_model = source
        .get("model")
        .filter(|value| !value.is_null())
        .cloned();
    let config_model = config.and_then(|config| config.get("model")).cloned();
    if typed_model.is_some() && config_model.is_some() && typed_model != config_model {
        return Err(CoreError::InvalidArgument);
    }
    let mut update = Map::new();
    update.insert("threadId".to_owned(), Value::String(thread_id.to_owned()));
    for key in [
        "cwd",
        "approvalPolicy",
        "approvalsReviewer",
        "permissions",
        "serviceTier",
        "personality",
    ] {
        if let Some(value) = source.get(key) {
            update.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(value) = typed_model.or(config_model) {
        update.insert("model".to_owned(), value);
    }
    if let Some(value) = config.and_then(|config| config.get("model_reasoning_effort")) {
        update.insert("effort".to_owned(), value.clone());
    }
    if let Some(value) = source.get("sandbox") {
        let policy = match value {
            Value::Null => None,
            Value::String(mode) if mode == "read-only" => Some(serde_json::json!({
                "type": "readOnly",
                "networkAccess": false,
            })),
            Value::String(mode) if mode == "workspace-write" => {
                Some(super::default_workspace_write_sandbox_policy())
            }
            Value::String(mode) if mode == "danger-full-access" => Some(serde_json::json!({
                "type": "dangerFullAccess",
            })),
            _ => return Err(CoreError::InvalidArgument),
        };
        if let Some(policy) = policy {
            update.insert("sandboxPolicy".to_owned(), policy);
        }
    }
    let typed: ThreadSettingsUpdateParams =
        serde_json::from_value(Value::Object(update)).map_err(|_| CoreError::InvalidArgument)?;
    typed.validate()?;
    let developer_instructions = match source.get("developerInstructions") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(value.clone()),
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    let mut settings = ThreadSettings::resolve(record, None, typed)?;
    settings.collaboration_mode.settings.developer_instructions = developer_instructions;
    validate_collaboration_mode(&settings.collaboration_mode)?;
    settings_value(&settings)
}

pub(super) fn apply(
    known_thread_ids: &HashSet<String>,
    records: &HashMap<String, ThreadRecord>,
    stored_settings: &mut HashMap<String, Value>,
    input: &[u8],
    sequence: u64,
) -> Result<Vec<Vec<u8>>, CoreError> {
    let mut command: Map<String, Value> =
        serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
    let official_notification = command
        .remove(OFFICIAL_NOTIFICATION_FIELD)
        .and_then(|value| value.as_bool())
        .unwrap_or(false);
    command.remove("kind");
    let params = parse_canonical_patch(known_thread_ids, &Value::Object(command))?;
    let record = records
        .get(&params.thread_id)
        .ok_or(CoreError::InvalidArgument)?;
    let existing = stored_settings.get(&params.thread_id);
    let effective = ThreadSettings::resolve(record, existing, params)?;
    let effective_value = settings_value(&effective)?;

    let event = if official_notification {
        serde_json::to_vec(&OfficialNotification {
            method: "thread/settings/updated",
            params: ThreadSettingsUpdatedNotification {
                thread_id: &effective.thread_id,
                thread_settings: &effective,
            },
        })
        .map_err(|_| CoreError::InvalidJson)?
    } else {
        serde_json::to_vec(&LegacyNotification {
            sequence,
            kind: "threadSettingsUpdated",
            thread_id: &effective.thread_id,
            thread_settings: &effective,
        })
        .map_err(|_| CoreError::InvalidJson)?
    };

    stored_settings.insert(effective.thread_id.clone(), effective_value);
    Ok(vec![event])
}

pub(super) fn merge_into_turn_params(
    known_thread_ids: &HashSet<String>,
    stored_settings: &HashMap<String, Value>,
    params: &Value,
) -> Result<Value, CoreError> {
    let requested_thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or(CoreError::InvalidArgument)?;
    let thread_id = canonical_thread_id(known_thread_ids, requested_thread_id)?;
    let mut effective = params
        .as_object()
        .cloned()
        .ok_or(CoreError::InvalidArgument)?;
    effective.insert("threadId".to_owned(), Value::String(thread_id.clone()));
    let Some(settings) = stored_settings.get(&thread_id) else {
        return Ok(Value::Object(effective));
    };
    let settings = settings.as_object().ok_or(CoreError::InvalidArgument)?;
    for field in [
        "cwd",
        "approvalPolicy",
        "approvalsReviewer",
        "sandboxPolicy",
        "model",
        "serviceTier",
        "effort",
        "summary",
        "collaborationMode",
        "personality",
    ] {
        if !effective.contains_key(field) {
            let value = settings
                .get(field)
                .cloned()
                .ok_or(CoreError::InvalidArgument)?;
            if field == "serviceTier"
                && (value.is_null() || value.as_str() == Some(SERVICE_TIER_DEFAULT))
            {
                continue;
            }
            effective.insert(field.to_owned(), value);
        }
    }
    Ok(Value::Object(effective))
}

pub(super) struct PreparedTurnSettingsPatch {
    pub(super) command: Option<Value>,
    pub(super) effective: Option<Value>,
}

pub(super) fn prepare_turn_patch(
    known_thread_ids: &HashSet<String>,
    records: &HashMap<String, ThreadRecord>,
    stored_settings: &HashMap<String, Value>,
    params: &Value,
) -> Result<PreparedTurnSettingsPatch, CoreError> {
    let source = params.as_object().ok_or(CoreError::InvalidArgument)?;
    let thread_id = source
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or(CoreError::InvalidArgument)?;
    let mut patch = Map::new();
    patch.insert("threadId".to_owned(), Value::String(thread_id.to_owned()));
    for field in [
        "cwd",
        "approvalPolicy",
        "approvalsReviewer",
        "sandboxPolicy",
        "permissions",
        "model",
        "serviceTier",
        "effort",
        "summary",
        "collaborationMode",
        "multiAgentMode",
        "personality",
    ] {
        if let Some(value) = source.get(field) {
            patch.insert(field.to_owned(), value.clone());
        }
    }

    let typed = parse_canonical_patch(known_thread_ids, &Value::Object(patch))?;
    if !typed.has_effective_update() {
        return Ok(PreparedTurnSettingsPatch {
            command: None,
            effective: stored_settings.get(&typed.thread_id).cloned(),
        });
    }

    let record = records
        .get(&typed.thread_id)
        .ok_or(CoreError::InvalidArgument)?;
    let existing = stored_settings.get(&typed.thread_id);
    let effective = ThreadSettings::resolve(record, existing, typed.clone())?;
    let effective_value = settings_value(&effective)?;
    let changed = !is_current_effective(record, existing, &typed.thread_id, &effective_value)?;
    let command = if changed {
        Some(serde_json::to_value(&typed).map_err(|_| CoreError::InvalidJson)?)
    } else {
        None
    };
    Ok(PreparedTurnSettingsPatch {
        command,
        effective: Some(effective_value),
    })
}

pub(super) fn merge_effective_settings_into_turn_params(
    params: &Value,
    settings: &Value,
) -> Result<Value, CoreError> {
    let mut effective = params
        .as_object()
        .cloned()
        .ok_or(CoreError::InvalidArgument)?;
    let settings = settings.as_object().ok_or(CoreError::InvalidArgument)?;
    for field in [
        "cwd",
        "approvalPolicy",
        "approvalsReviewer",
        "sandboxPolicy",
        "model",
        "effort",
        "summary",
        "collaborationMode",
        "personality",
    ] {
        let value = settings
            .get(field)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        effective.insert(field.to_owned(), value);
    }
    effective.remove("permissions");
    match settings.get("serviceTier") {
        Some(Value::String(tier)) if tier != SERVICE_TIER_DEFAULT => {
            effective.insert("serviceTier".to_owned(), Value::String(tier.clone()));
        }
        Some(Value::Null) | Some(Value::String(_)) => {
            effective.remove("serviceTier");
        }
        _ => return Err(CoreError::InvalidArgument),
    }
    Ok(Value::Object(effective))
}

pub(super) fn apply_turn_patch(
    known_thread_ids: &HashSet<String>,
    records: &HashMap<String, ThreadRecord>,
    stored_settings: &mut HashMap<String, Value>,
    patch: Option<&Value>,
) -> Result<Option<Vec<u8>>, CoreError> {
    let Some(patch) = patch else {
        return Ok(None);
    };
    let typed = parse_canonical_patch(known_thread_ids, patch)?;
    if !typed.has_effective_update() {
        return Ok(None);
    }
    let record = records
        .get(&typed.thread_id)
        .ok_or(CoreError::InvalidArgument)?;
    let existing = stored_settings.get(&typed.thread_id);
    let effective = ThreadSettings::resolve(record, existing, typed)?;
    let effective_value = settings_value(&effective)?;
    if is_current_effective(record, existing, &effective.thread_id, &effective_value)? {
        return Ok(None);
    }
    let event = encode_official_notification(&effective)?;
    stored_settings.insert(effective.thread_id.clone(), effective_value);
    Ok(Some(event))
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ThreadSettingsUpdateParams {
    thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approval_policy: Option<AskForApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    approvals_reviewer: Option<ApprovalsReviewer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sandbox_policy: Option<SandboxPolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    permissions: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(default, skip_serializing_if = "NullablePatch::is_missing")]
    service_tier: NullablePatch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    summary: Option<ReasoningSummary>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    collaboration_mode: Option<CollaborationMode>,
    #[serde(default, rename = "multiAgentMode", skip_serializing)]
    _multi_agent_mode: Option<MultiAgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    personality: Option<Personality>,
}

impl ThreadSettingsUpdateParams {
    fn validate(&self) -> Result<(), CoreError> {
        if self.permissions.is_some() && self.sandbox_policy.is_some() {
            return Err(CoreError::InvalidArgument);
        }
        if self
            .model
            .as_deref()
            .is_some_and(|model| model.trim().is_empty())
            || self
                .permissions
                .as_deref()
                .is_some_and(|profile| profile.trim().is_empty())
            || self
                .effort
                .as_deref()
                .is_some_and(|effort| effort.is_empty())
            || matches!(
                &self.service_tier,
                NullablePatch::Value(tier) if tier.trim().is_empty()
            )
            || self
                .collaboration_mode
                .as_ref()
                .and_then(|mode| mode.settings.reasoning_effort.as_deref())
                .is_some_and(|effort| effort.is_empty())
        {
            return Err(CoreError::InvalidArgument);
        }
        Ok(())
    }

    fn empty(thread_id: String) -> Self {
        Self {
            thread_id,
            cwd: None,
            approval_policy: None,
            approvals_reviewer: None,
            sandbox_policy: None,
            permissions: None,
            model: None,
            service_tier: NullablePatch::Missing,
            effort: None,
            summary: None,
            collaboration_mode: None,
            _multi_agent_mode: None,
            personality: None,
        }
    }

    fn has_effective_update(&self) -> bool {
        self.cwd.is_some()
            || self.approval_policy.is_some()
            || self.approvals_reviewer.is_some()
            || self.sandbox_policy.is_some()
            || self.permissions.is_some()
            || self.model.is_some()
            || !matches!(&self.service_tier, NullablePatch::Missing)
            || self.effort.is_some()
            || self.summary.is_some()
            || self.collaboration_mode.is_some()
            || self.personality.is_some()
    }
}

#[derive(Clone, Default)]
enum NullablePatch<T> {
    #[default]
    Missing,
    Null,
    Value(T),
}

impl<T> NullablePatch<T> {
    fn is_missing(&self) -> bool {
        matches!(self, Self::Missing)
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for NullablePatch<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

impl<T: Serialize> Serialize for NullablePatch<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Missing | Self::Null => serializer.serialize_none(),
            Self::Value(value) => value.serialize(serializer),
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum AskForApproval {
    Mode(ApprovalMode),
    Granular(GranularAskForApproval),
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ApprovalMode {
    Untrusted,
    OnRequest,
    Never,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct GranularAskForApproval {
    granular: GranularApprovalSettings,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct GranularApprovalSettings {
    sandbox_approval: bool,
    rules: bool,
    #[serde(default)]
    skill_approval: bool,
    #[serde(default)]
    request_permissions: bool,
    mcp_elicitations: bool,
}

#[derive(Clone, Copy, Default, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum ApprovalsReviewer {
    #[default]
    User,
    AutoReview,
    GuardianSubagent,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
enum SandboxPolicy {
    DangerFullAccess,
    ReadOnly {
        #[serde(default, rename = "networkAccess")]
        network_access: bool,
    },
    ExternalSandbox {
        #[serde(default, rename = "networkAccess")]
        network_access: NetworkAccess,
    },
    WorkspaceWrite {
        #[serde(default, rename = "writableRoots")]
        writable_roots: Vec<String>,
        #[serde(default, rename = "networkAccess")]
        network_access: bool,
        #[serde(default, rename = "excludeTmpdirEnvVar")]
        exclude_tmpdir_env_var: bool,
        #[serde(default, rename = "excludeSlashTmp")]
        exclude_slash_tmp: bool,
    },
}

impl Default for SandboxPolicy {
    fn default() -> Self {
        Self::WorkspaceWrite {
            writable_roots: Vec::new(),
            network_access: false,
            exclude_tmpdir_env_var: false,
            exclude_slash_tmp: false,
        }
    }
}

impl SandboxPolicy {
    fn normalize(mut self) -> Result<Self, CoreError> {
        if let Self::WorkspaceWrite { writable_roots, .. } = &mut self {
            for root in writable_roots {
                *root = normalize_absolute_path(root)?;
            }
        }
        Ok(self)
    }
}

#[derive(Clone, Copy, Default, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum NetworkAccess {
    #[default]
    Restricted,
    Enabled,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum ReasoningSummary {
    Auto,
    Concise,
    Detailed,
    None,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Personality {
    None,
    Friendly,
    Pragmatic,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CollaborationMode {
    mode: ModeKind,
    settings: CollaborationSettings,
}

impl CollaborationMode {
    fn default_for(model: &str, effort: Option<&str>) -> Self {
        Self {
            mode: ModeKind::Default,
            settings: CollaborationSettings {
                model: model.to_owned(),
                reasoning_effort: effort.map(str::to_owned),
                developer_instructions: None,
            },
        }
    }
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum ModeKind {
    Plan,
    Default,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CollaborationSettings {
    model: String,
    #[serde(default)]
    reasoning_effort: Option<String>,
    #[serde(default)]
    developer_instructions: Option<String>,
}

#[derive(Clone)]
struct MultiAgentMode;

impl<'de> Deserialize<'de> for MultiAgentMode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = Value::deserialize(deserializer)?;
        let valid = matches!(value.as_str(), Some("explicitRequestOnly" | "proactive"))
            || value.as_object().is_some_and(|object| {
                object.len() == 1 && object.get("custom").is_some_and(Value::is_string)
            });
        if valid {
            Ok(Self)
        } else {
            Err(SerdeError::custom("invalid multi-agent mode"))
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
struct ActivePermissionProfile {
    id: String,
    #[serde(default)]
    extends: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSettings {
    #[serde(skip)]
    thread_id: String,
    cwd: String,
    approval_policy: AskForApproval,
    approvals_reviewer: ApprovalsReviewer,
    sandbox_policy: SandboxPolicy,
    active_permission_profile: Option<ActivePermissionProfile>,
    model: String,
    model_provider: String,
    service_tier: Option<String>,
    effort: Option<String>,
    summary: Option<ReasoningSummary>,
    collaboration_mode: CollaborationMode,
    multi_agent_mode: &'static str,
    personality: Option<Personality>,
}

impl ThreadSettings {
    fn resolve(
        record: &ThreadRecord,
        existing: Option<&Value>,
        params: ThreadSettingsUpdateParams,
    ) -> Result<Self, CoreError> {
        let existing = match existing {
            Some(Value::Object(settings)) => Some(settings),
            Some(_) => return Err(CoreError::InvalidArgument),
            None => None,
        };

        let official = record.has_official_metadata();
        let model_provider = non_empty(
            existing_string(existing, "modelProvider")?
                .or_else(|| {
                    (!record.model_provider().is_empty())
                        .then(|| record.model_provider().to_owned())
                })
                .ok_or(CoreError::InvalidArgument)?,
        )?;
        let openai_defaults = official && model_provider == "openai";
        let cwd = resolve_request_cwd(
            &params
                .cwd
                .or(existing_string(existing, "cwd")?)
                .or_else(|| (!record.cwd().is_empty()).then(|| record.cwd().to_owned()))
                .ok_or(CoreError::InvalidArgument)?,
        )?;
        let model_was_explicit = params.model.is_some();
        let effort_was_explicit = params.effort.is_some();
        let mut model = non_empty(
            params
                .model
                .or(existing_string(existing, "model")?)
                .or_else(|| openai_defaults.then(|| OFFICIAL_OPENAI_DEFAULT_MODEL.to_owned()))
                .ok_or(CoreError::InvalidArgument)?,
        )?;
        let mut effort = params
            .effort
            .or(existing_string(existing, "effort")?)
            .or_else(|| openai_defaults.then(|| OFFICIAL_OPENAI_DEFAULT_EFFORT.to_owned()))
            .map(non_empty_reasoning)
            .transpose()?;
        let approval_policy = params
            .approval_policy
            .or(existing_typed(existing, "approvalPolicy")?)
            .or_else(|| official.then_some(AskForApproval::Mode(ApprovalMode::OnRequest)))
            .ok_or(CoreError::InvalidArgument)?;
        let approvals_reviewer = params
            .approvals_reviewer
            .or(existing_typed(existing, "approvalsReviewer")?)
            .unwrap_or_default();
        let explicit_sandbox = params.sandbox_policy.is_some();
        let (active_permission_profile, sandbox_policy) = match params.permissions {
            Some(id) => {
                let (profile, policy) = resolve_permission_profile(&id)?;
                (Some(profile), policy)
            }
            None => (
                if explicit_sandbox {
                    None
                } else {
                    existing_typed(existing, "activePermissionProfile")?
                },
                params
                    .sandbox_policy
                    .or(existing_typed(existing, "sandboxPolicy")?)
                    .unwrap_or_default()
                    .normalize()?,
            ),
        };
        let service_tier = match params.service_tier {
            NullablePatch::Missing => existing_string(existing, "serviceTier")?,
            NullablePatch::Null => Some(SERVICE_TIER_DEFAULT.to_owned()),
            NullablePatch::Value(value) => Some(non_empty(value)?),
        };
        let summary = params
            .summary
            .or(existing_typed(existing, "summary")?)
            .or_else(|| openai_defaults.then_some(ReasoningSummary::None));
        let personality = params
            .personality
            .or(existing_typed(existing, "personality")?);
        let collaboration_mode = match params.collaboration_mode {
            Some(mode) => {
                validate_collaboration_mode(&mode)?;
                model = mode.settings.model.clone();
                effort = mode.settings.reasoning_effort.clone();
                mode
            }
            None => {
                let mut mode = existing_typed(existing, "collaborationMode")?
                    .unwrap_or_else(|| CollaborationMode::default_for(&model, effort.as_deref()));
                if model_was_explicit {
                    mode.settings.model = model.clone();
                }
                if effort_was_explicit {
                    mode.settings.reasoning_effort = effort.clone();
                }
                validate_collaboration_mode(&mode)?;
                model = mode.settings.model.clone();
                effort = mode.settings.reasoning_effort.clone();
                mode
            }
        };
        validate_collaboration_mode(&collaboration_mode)?;

        Ok(Self {
            thread_id: params.thread_id,
            cwd,
            approval_policy,
            approvals_reviewer,
            sandbox_policy,
            active_permission_profile,
            model,
            model_provider,
            service_tier,
            effort,
            summary,
            collaboration_mode,
            multi_agent_mode: "explicitRequestOnly",
            personality,
        })
    }
}

#[derive(Serialize)]
struct OfficialNotification<'a> {
    method: &'static str,
    params: ThreadSettingsUpdatedNotification<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSettingsUpdatedNotification<'a> {
    thread_id: &'a str,
    thread_settings: &'a ThreadSettings,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LegacyNotification<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    thread_settings: &'a ThreadSettings,
}

fn parse_canonical_patch(
    known_thread_ids: &HashSet<String>,
    params: &Value,
) -> Result<ThreadSettingsUpdateParams, CoreError> {
    let bytes = serde_json::to_vec(params).map_err(|_| CoreError::InvalidJson)?;
    if bytes.len() > MAX_SETTINGS_PATCH_BYTES {
        return Err(CoreError::InvalidArgument);
    }
    let mut typed: ThreadSettingsUpdateParams =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    typed.validate()?;
    typed.thread_id = canonical_thread_id(known_thread_ids, &typed.thread_id)?;
    if let Some(cwd) = typed.cwd.as_deref() {
        typed.cwd = Some(resolve_request_cwd(cwd)?);
    }
    if let Some(profile) = typed.permissions.as_deref() {
        resolve_permission_profile(profile)?;
    }
    Ok(typed)
}

pub(super) fn canonical_thread_id(
    known_thread_ids: &HashSet<String>,
    requested: &str,
) -> Result<String, CoreError> {
    validate_thread_id(requested)?;
    known_thread_ids
        .iter()
        .find(|known| known.eq_ignore_ascii_case(requested))
        .cloned()
        .ok_or(CoreError::InvalidArgument)
}

fn settings_value(settings: &ThreadSettings) -> Result<Value, CoreError> {
    serde_json::to_value(settings).map_err(|_| CoreError::InvalidJson)
}

fn is_current_effective(
    record: &ThreadRecord,
    existing: Option<&Value>,
    thread_id: &str,
    candidate: &Value,
) -> Result<bool, CoreError> {
    if let Some(existing) = existing {
        if !existing.is_object() {
            return Err(CoreError::InvalidArgument);
        }
        return Ok(existing == candidate);
    }
    let baseline = ThreadSettings::resolve(
        record,
        None,
        ThreadSettingsUpdateParams::empty(thread_id.to_owned()),
    )
    .and_then(|settings| settings_value(&settings));
    match baseline {
        Ok(baseline) => Ok(&baseline == candidate),
        Err(CoreError::InvalidArgument) => Ok(false),
        Err(error) => Err(error),
    }
}

fn encode_official_notification(settings: &ThreadSettings) -> Result<Vec<u8>, CoreError> {
    serde_json::to_vec(&OfficialNotification {
        method: "thread/settings/updated",
        params: ThreadSettingsUpdatedNotification {
            thread_id: &settings.thread_id,
            thread_settings: settings,
        },
    })
    .map_err(|_| CoreError::InvalidJson)
}

fn resolve_permission_profile(
    id: &str,
) -> Result<(ActivePermissionProfile, SandboxPolicy), CoreError> {
    let sandbox_policy = match id {
        ":read-only" => SandboxPolicy::ReadOnly {
            network_access: false,
        },
        ":workspace" => SandboxPolicy::default(),
        ":danger-full-access" => SandboxPolicy::DangerFullAccess,
        _ => return Err(CoreError::InvalidArgument),
    };
    Ok((
        ActivePermissionProfile {
            id: id.to_owned(),
            extends: None,
        },
        sandbox_policy,
    ))
}

fn validate_thread_id(thread_id: &str) -> Result<(), CoreError> {
    let bytes = thread_id.as_bytes();
    if bytes.len() != 36 {
        return Err(CoreError::InvalidArgument);
    }
    for (index, byte) in bytes.iter().copied().enumerate() {
        let separator = matches!(index, 8 | 13 | 18 | 23);
        if (separator && byte != b'-') || (!separator && !byte.is_ascii_hexdigit()) {
            return Err(CoreError::InvalidArgument);
        }
    }
    Ok(())
}

fn existing_string(
    settings: Option<&Map<String, Value>>,
    field: &str,
) -> Result<Option<String>, CoreError> {
    let Some(value) = settings.and_then(|settings| settings.get(field)) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    value
        .as_str()
        .map(|value| Some(value.to_owned()))
        .ok_or(CoreError::InvalidArgument)
}

fn existing_typed<T: DeserializeOwned>(
    settings: Option<&Map<String, Value>>,
    field: &str,
) -> Result<Option<T>, CoreError> {
    let Some(value) = settings.and_then(|settings| settings.get(field)) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    serde_json::from_value(value.clone())
        .map(Some)
        .map_err(|_| CoreError::InvalidArgument)
}

fn non_empty(value: String) -> Result<String, CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(value)
    }
}

fn non_empty_reasoning(value: String) -> Result<String, CoreError> {
    if value.is_empty() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(value)
    }
}

pub(super) fn resolve_request_cwd(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|_| CoreError::InvalidArgument)?
            .join(path)
    };
    normalize_path(absolute)
}

fn normalize_absolute_path(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    if !path.is_absolute() {
        return Err(CoreError::InvalidArgument);
    }
    normalize_path(path.to_path_buf())
}

fn normalize_path(path: PathBuf) -> Result<String, CoreError> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
        }
    }
    normalized
        .into_os_string()
        .into_string()
        .map_err(|_| CoreError::InvalidArgument)
}

fn validate_collaboration_mode(mode: &CollaborationMode) -> Result<(), CoreError> {
    non_empty(mode.settings.model.clone())?;
    if mode
        .settings
        .reasoning_effort
        .as_deref()
        .is_some_and(str::is_empty)
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}
