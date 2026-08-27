use super::thread_directory::{self, Thread, ThreadRecord};
use super::{
    ThreadItemWire, TurnWire, default_workspace_write_sandbox_policy, normalize_approval_policy,
    normalize_sandbox_policy,
};
use crate::CoreError;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;

pub(super) fn resume(
    records: &HashMap<String, ThreadRecord>,
    settings: &HashMap<String, Value>,
    turn_order: &[String],
    turns: &HashMap<String, TurnWire>,
    item_order: &[String],
    items: &HashMap<String, ThreadItemWire>,
    params: &Value,
) -> Result<Vec<u8>, CoreError> {
    let raw_params = params;
    let params: ThreadResumeParams =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    if params.thread_id.trim().is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    let record = records
        .get(&params.thread_id)
        .filter(|record| record.has_official_metadata())
        .ok_or(CoreError::InvalidArgument)?;
    let persisted_settings = settings.get(&params.thread_id);
    // Instruction changes must reach the live executor. Resume accepts only
    // persisted instructions or the released renderer's hydration echo.
    validate_instruction_overrides(&params, raw_params, persisted_settings)?;
    let effective = EffectiveResumeSettings::resolve(record, persisted_settings, &params)?;
    let active_permission_profile = match persisted_settings {
        None => None,
        Some(Value::Object(settings)) => settings
            .get("activePermissionProfile")
            .filter(|value| !value.is_null())
            .cloned(),
        Some(_) => return Err(CoreError::InvalidArgument),
    };

    let thread = thread_directory::project_thread(
        record, turn_order, turns, item_order, items, /*include_turns*/ true,
    );
    serde_json::to_vec(&ThreadResumeResponse {
        thread,
        model: effective.model,
        model_provider: effective.model_provider,
        service_tier: effective.service_tier,
        cwd: effective.cwd,
        runtime_workspace_roots: record
            .runtime()
            .runtime_workspace_roots
            .clone()
            .unwrap_or_default(),
        dynamic_tools: record.runtime().dynamic_tools.clone().unwrap_or_default(),
        selected_capability_roots: record
            .runtime()
            .selected_capability_roots
            .clone()
            .unwrap_or_default(),
        instruction_sources: Vec::new(),
        approval_policy: effective.approval_policy,
        approvals_reviewer: effective.approvals_reviewer,
        sandbox: effective.sandbox,
        active_permission_profile,
        reasoning_effort: effective.reasoning_effort,
        multi_agent_mode: "explicitRequestOnly",
    })
    .map_err(|_| CoreError::InvalidJson)
}

pub(super) fn resolve_fork_settings(
    record: &ThreadRecord,
    settings: Option<&Value>,
    params: &Value,
) -> Result<Value, CoreError> {
    let mut fork_params = params.clone();
    hydrate_fork_model_group(record, settings, &mut fork_params)?;
    let params: ThreadResumeParams =
        serde_json::from_value(fork_params).map_err(|_| CoreError::InvalidArgument)?;
    reject_unconsumed_fork_overrides(&params)?;
    let effective = EffectiveResumeSettings::resolve(record, settings, &params)?;
    let mut persisted = match settings {
        Some(Value::Object(settings)) => settings.clone(),
        Some(_) => return Err(CoreError::InvalidArgument),
        None => serde_json::Map::new(),
    };
    if let Some(config) = params.config.as_ref() {
        for (key, value) in config {
            if !matches!(key.as_str(), "model" | "model_reasoning_effort") {
                persisted.insert(key.clone(), value.clone());
            }
        }
    }
    synchronize_fork_collaboration_mode(
        &mut persisted,
        &effective.model,
        effective.reasoning_effort.as_deref(),
        params.developer_instructions.as_deref(),
    )?;
    persisted.insert("model".to_owned(), Value::String(effective.model));
    persisted.insert(
        "modelProvider".to_owned(),
        Value::String(effective.model_provider),
    );
    persisted.insert(
        "serviceTier".to_owned(),
        effective.service_tier.map_or(Value::Null, Value::String),
    );
    persisted.insert("cwd".to_owned(), Value::String(effective.cwd));
    persisted.insert("approvalPolicy".to_owned(), effective.approval_policy);
    persisted.insert(
        "approvalsReviewer".to_owned(),
        Value::String(effective.approvals_reviewer),
    );
    persisted.insert("sandboxPolicy".to_owned(), effective.sandbox);
    persisted.insert(
        "effort".to_owned(),
        effective
            .reasoning_effort
            .map_or(Value::Null, Value::String),
    );
    Ok(Value::Object(persisted))
}

fn hydrate_fork_model_group(
    record: &ThreadRecord,
    settings: Option<&Value>,
    params: &mut Value,
) -> Result<(), CoreError> {
    let object = params.as_object_mut().ok_or(CoreError::InvalidArgument)?;
    let has_config_model_override =
        object
            .get("config")
            .and_then(Value::as_object)
            .is_some_and(|config| {
                config.contains_key("model") || config.contains_key("model_reasoning_effort")
            });
    if !object.contains_key("model") && !has_config_model_override {
        return Ok(());
    }
    let persisted = match settings {
        Some(Value::Object(settings)) => Some(settings),
        Some(_) => return Err(CoreError::InvalidArgument),
        None => None,
    };
    if !object.contains_key("model") {
        let model = string_setting(persisted, "model")?.ok_or(CoreError::InvalidArgument)?;
        object.insert("model".to_owned(), Value::String(model));
    }
    if !object.contains_key("modelProvider") {
        let provider =
            required_string_setting(persisted, "modelProvider", record.model_provider())?;
        object.insert("modelProvider".to_owned(), Value::String(provider));
    }
    Ok(())
}

fn reject_unconsumed_fork_overrides(params: &ThreadResumeParams) -> Result<(), CoreError> {
    if params.base_instructions.is_some() || params.personality.is_some() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(())
    }
}

fn synchronize_fork_collaboration_mode(
    persisted: &mut serde_json::Map<String, Value>,
    model: &str,
    reasoning_effort: Option<&str>,
    developer_instructions: Option<&str>,
) -> Result<(), CoreError> {
    let mut collaboration_mode = match persisted.remove("collaborationMode") {
        Some(Value::Object(mode)) => mode,
        Some(_) => return Err(CoreError::InvalidArgument),
        None => serde_json::Map::new(),
    };
    match collaboration_mode.get("mode") {
        Some(Value::String(mode)) if matches!(mode.as_str(), "default" | "plan") => {}
        Some(_) => return Err(CoreError::InvalidArgument),
        None => {
            collaboration_mode.insert("mode".to_owned(), Value::String("default".to_owned()));
        }
    }
    let mut collaboration_settings = match collaboration_mode.remove("settings") {
        Some(Value::Object(settings)) => settings,
        Some(_) => return Err(CoreError::InvalidArgument),
        None => serde_json::Map::new(),
    };
    collaboration_settings.insert("model".to_owned(), Value::String(model.to_owned()));
    collaboration_settings.insert(
        "reasoning_effort".to_owned(),
        reasoning_effort.map_or(Value::Null, |effort| Value::String(effort.to_owned())),
    );
    if let Some(developer_instructions) = developer_instructions {
        collaboration_settings.insert(
            "developer_instructions".to_owned(),
            Value::String(developer_instructions.to_owned()),
        );
    } else if !collaboration_settings.contains_key("developer_instructions") {
        collaboration_settings.insert("developer_instructions".to_owned(), Value::Null);
    }
    collaboration_mode.insert("settings".to_owned(), Value::Object(collaboration_settings));
    persisted.insert(
        "collaborationMode".to_owned(),
        Value::Object(collaboration_mode),
    );
    Ok(())
}

fn validate_instruction_overrides(
    params: &ThreadResumeParams,
    raw_params: &Value,
    settings: Option<&Value>,
) -> Result<(), CoreError> {
    if params.base_instructions.is_some() {
        return Err(CoreError::InvalidArgument);
    }
    let settings = match settings {
        Some(Value::Object(settings)) => Some(settings),
        Some(_) => return Err(CoreError::InvalidArgument),
        None => None,
    };
    if let Some(developer_instructions) = params.developer_instructions.as_deref() {
        match persisted_developer_instructions(settings)? {
            Some(persisted) if persisted == developer_instructions => {}
            None if is_released_renderer_hydration_echo(raw_params) => {}
            _ => return Err(CoreError::InvalidArgument),
        }
    }
    if let Some(personality) = params.personality {
        match optional_string_setting(settings, "personality")? {
            Some(persisted) if persisted == personality.as_str() => {}
            None if is_released_renderer_hydration_echo(raw_params) => {}
            _ => return Err(CoreError::InvalidArgument),
        }
    }
    Ok(())
}

fn is_released_renderer_hydration_echo(params: &Value) -> bool {
    let Some(params) = params.as_object() else {
        return false;
    };
    params.get("model") == Some(&Value::Null)
        && params.get("modelProvider") == Some(&Value::Null)
        && params.get("config").is_some_and(Value::is_object)
        && params.get("cwd").is_some_and(Value::is_string)
        && params.get("personality").is_some_and(Value::is_string)
}

fn persisted_developer_instructions(
    settings: Option<&serde_json::Map<String, Value>>,
) -> Result<Option<String>, CoreError> {
    let collaboration_mode = match settings.and_then(|settings| settings.get("collaborationMode")) {
        None => return Ok(None),
        Some(Value::Object(mode)) => mode,
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    let collaboration_settings = match collaboration_mode.get("settings") {
        None => return Ok(None),
        Some(Value::Object(settings)) => settings,
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    optional_string_setting(Some(collaboration_settings), "developer_instructions")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadResumeParams {
    thread_id: String,
    #[serde(default)]
    model: NullableOverride<String>,
    model_provider: Option<String>,
    #[serde(default)]
    service_tier: NullableOverride<String>,
    cwd: Option<String>,
    approval_policy: Option<Value>,
    approvals_reviewer: Option<ApprovalsReviewer>,
    sandbox: Option<SandboxMode>,
    config: Option<HashMap<String, Value>>,
    base_instructions: Option<String>,
    developer_instructions: Option<String>,
    personality: Option<Personality>,
}

#[derive(Default)]
enum NullableOverride<T> {
    #[default]
    Missing,
    Null,
    Value(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for NullableOverride<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ApprovalsReviewer {
    User,
    AutoReview,
    GuardianSubagent,
}

impl ApprovalsReviewer {
    fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::AutoReview => "auto_review",
            Self::GuardianSubagent => "guardian_subagent",
        }
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum SandboxMode {
    ReadOnly,
    WorkspaceWrite,
    DangerFullAccess,
}

impl SandboxMode {
    fn policy(self) -> Value {
        match self {
            Self::ReadOnly => serde_json::json!({
                "type": "readOnly",
                "networkAccess": false,
            }),
            Self::WorkspaceWrite => default_workspace_write_sandbox_policy(),
            Self::DangerFullAccess => serde_json::json!({
                "type": "dangerFullAccess",
            }),
        }
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Personality {
    None,
    Friendly,
    Pragmatic,
}

impl Personality {
    fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Friendly => "friendly",
            Self::Pragmatic => "pragmatic",
        }
    }
}

struct EffectiveResumeSettings {
    model: String,
    model_provider: String,
    service_tier: Option<String>,
    cwd: String,
    approval_policy: Value,
    approvals_reviewer: String,
    sandbox: Value,
    reasoning_effort: Option<String>,
}

impl EffectiveResumeSettings {
    fn resolve(
        record: &ThreadRecord,
        settings: Option<&Value>,
        overrides: &ThreadResumeParams,
    ) -> Result<Self, CoreError> {
        let settings = match settings {
            Some(Value::Object(settings)) => Some(settings),
            Some(_) => return Err(CoreError::InvalidArgument),
            None => None,
        };

        let config = overrides.config.as_ref();
        let persisted_model = string_setting(settings, "model")?;
        let typed_model = match &overrides.model {
            NullableOverride::Missing | NullableOverride::Null => None,
            NullableOverride::Value(value) => Some(non_empty_string(value.clone())?),
        };
        let mut config_model = config_string_override(config, "model")?;
        if typed_model.is_none() && config_model.as_deref() == persisted_model.as_deref() {
            config_model = None;
        }
        let explicit_model = match (typed_model, config_model) {
            (Some(typed), Some(configured)) if typed != configured => {
                return Err(CoreError::InvalidArgument);
            }
            (Some(typed), _) => Some(typed),
            (None, configured) => configured,
        };
        let explicit_model_provider = overrides
            .model_provider
            .clone()
            .map(non_empty_string)
            .transpose()?;
        let explicit_reasoning = config_string_override(config, "model_reasoning_effort")?;
        let (model, model_provider, reasoning_effort) = if let Some(model) = explicit_model {
            // A real model identity change must remain complete. Core cannot
            // infer a different provider's default model truthfully.
            (
                model,
                explicit_model_provider.ok_or(CoreError::InvalidArgument)?,
                explicit_reasoning,
            )
        } else {
            let persisted_model = persisted_model.ok_or(CoreError::InvalidArgument)?;
            let persisted_provider =
                required_string_setting(settings, "modelProvider", record.model_provider())?;
            let persisted_reasoning = optional_string_setting(settings, "effort")?;
            if explicit_model_provider
                .as_deref()
                .is_some_and(|provider| provider != persisted_provider)
            {
                return Err(CoreError::InvalidArgument);
            }
            (
                persisted_model,
                persisted_provider,
                explicit_reasoning.or(persisted_reasoning),
            )
        };
        let cwd = overrides
            .cwd
            .clone()
            .map(absolute_path)
            .transpose()?
            .unwrap_or(required_absolute_path_setting(
                settings,
                "cwd",
                record.cwd(),
            )?);
        let service_tier = match &overrides.service_tier {
            NullableOverride::Missing => optional_string_setting(settings, "serviceTier")?,
            NullableOverride::Null => None,
            NullableOverride::Value(value) => Some(non_empty_string(value.clone())?),
        };
        let approval_policy = normalize_approval_policy(
            overrides
                .approval_policy
                .clone()
                .or_else(|| {
                    settings
                        .and_then(|settings| settings.get("approvalPolicy"))
                        .cloned()
                })
                .ok_or(CoreError::InvalidArgument)?,
        )?;
        let approvals_reviewer = match overrides.approvals_reviewer {
            Some(value) => value.as_str().to_owned(),
            None => settings
                .and_then(|settings| settings.get("approvalsReviewer"))
                .map(parse_approvals_reviewer)
                .transpose()?
                .ok_or(CoreError::InvalidArgument)?,
        };
        let sandbox = normalize_sandbox_policy(
            overrides
                .sandbox
                .map(SandboxMode::policy)
                .or_else(|| {
                    settings
                        .and_then(|settings| settings.get("sandboxPolicy"))
                        .cloned()
                })
                .ok_or(CoreError::InvalidArgument)?,
        )?;
        Ok(Self {
            model,
            model_provider,
            service_tier,
            cwd,
            approval_policy,
            approvals_reviewer,
            sandbox,
            reasoning_effort,
        })
    }
}

fn config_string_override(
    config: Option<&HashMap<String, Value>>,
    name: &str,
) -> Result<Option<String>, CoreError> {
    match config.and_then(|config| config.get(name)) {
        None => Ok(None),
        Some(Value::String(value)) => non_empty_string(value.clone()).map(Some),
        Some(_) => Err(CoreError::InvalidArgument),
    }
}

fn string_setting(
    settings: Option<&serde_json::Map<String, Value>>,
    name: &str,
) -> Result<Option<String>, CoreError> {
    match settings.and_then(|settings| settings.get(name)) {
        None => Ok(None),
        Some(Value::String(value)) => non_empty_string(value.clone()).map(Some),
        Some(_) => Err(CoreError::InvalidArgument),
    }
}

fn required_string_setting(
    settings: Option<&serde_json::Map<String, Value>>,
    name: &str,
    fallback: &str,
) -> Result<String, CoreError> {
    match settings.and_then(|settings| settings.get(name)) {
        Some(Value::String(value)) => non_empty_string(value.clone()),
        Some(_) => Err(CoreError::InvalidArgument),
        None => non_empty_string(fallback.to_owned()),
    }
}

fn required_absolute_path_setting(
    settings: Option<&serde_json::Map<String, Value>>,
    name: &str,
    fallback: &str,
) -> Result<String, CoreError> {
    match settings.and_then(|settings| settings.get(name)) {
        Some(Value::String(value)) => absolute_path(value.clone()),
        Some(_) => Err(CoreError::InvalidArgument),
        None => absolute_path(fallback.to_owned()),
    }
}

fn optional_string_setting(
    settings: Option<&serde_json::Map<String, Value>>,
    name: &str,
) -> Result<Option<String>, CoreError> {
    match settings.and_then(|settings| settings.get(name)) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if name == "serviceTier" && value == "default" => Ok(None),
        Some(Value::String(value)) => non_empty_string(value.clone()).map(Some),
        Some(_) => Err(CoreError::InvalidArgument),
    }
}

fn parse_approvals_reviewer(value: &Value) -> Result<String, CoreError> {
    match value.as_str() {
        Some("user" | "auto_review" | "guardian_subagent") => {
            Ok(value.as_str().unwrap_or_default().to_owned())
        }
        _ => Err(CoreError::InvalidArgument),
    }
}

fn non_empty_string(value: String) -> Result<String, CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(value)
    }
}

fn absolute_path(value: String) -> Result<String, CoreError> {
    if value.trim().is_empty() || !Path::new(&value).is_absolute() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(value)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadResumeResponse {
    thread: Thread,
    model: String,
    model_provider: String,
    service_tier: Option<String>,
    cwd: String,
    runtime_workspace_roots: Vec<String>,
    dynamic_tools: Vec<Value>,
    selected_capability_roots: Vec<Value>,
    instruction_sources: Vec<String>,
    approval_policy: Value,
    approvals_reviewer: String,
    sandbox: Value,
    active_permission_profile: Option<Value>,
    reasoning_effort: Option<String>,
    multi_agent_mode: &'static str,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::thread_directory::ThreadCreateMetadata;
    use serde_json::json;

    fn record() -> ThreadRecord {
        let metadata: ThreadCreateMetadata = serde_json::from_value(json!({
            "sessionId": "resume-model-boundary",
            "preview": "",
            "ephemeral": false,
            "modelProvider": "persisted-provider",
            "createdAt": 100,
            "updatedAt": 100,
            "cwd": "/workspace",
            "cliVersion": "0.146.0-alpha.3.1",
            "source": "appServer"
        }))
        .unwrap();
        ThreadRecord::from_metadata(
            "00000000-0000-0000-0000-000000000002".to_owned(),
            "Resume model boundary".to_owned(),
            "00000000-0000-0000-0000-000000000001".to_owned(),
            Some(metadata),
        )
        .unwrap()
    }

    fn persisted_settings() -> Value {
        json!({
            "model": "persisted-model",
            "modelProvider": "persisted-provider",
            "effort": "ultra",
            "cwd": "/workspace",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandboxPolicy": {
                "type": "readOnly",
                "networkAccess": false
            }
        })
    }

    #[test]
    fn released_renderer_hydration_echo_resumes_without_overwriting_persisted_identity() {
        let thread_id = "00000000-0000-0000-0000-000000000002";
        let records = HashMap::from([(thread_id.to_owned(), record())]);
        let settings = HashMap::from([(thread_id.to_owned(), persisted_settings())]);
        let params = json!({
            "threadId": thread_id,
            "model": null,
            "modelProvider": null,
            "cwd": "/workspace",
            "developerInstructions": "released renderer hydration instructions",
            "personality": "pragmatic",
            "config": {
                "ambient-suggestions-enabled": true,
                "features.collaboration_modes": true,
                "model": "persisted-model",
                "model_reasoning_effort": "ultra"
            },
            "excludeTurns": [],
            "history": [],
            "initialTurnsPage": null
        });

        assert!(is_released_renderer_hydration_echo(&params));

        let response = resume(
            &records,
            &settings,
            &[],
            &HashMap::new(),
            &[],
            &HashMap::new(),
            &params,
        )
        .expect("released renderer hydration echo should resume the persisted thread");
        let response: Value = serde_json::from_slice(&response).unwrap();

        assert_eq!(response["model"], "persisted-model");
        assert_eq!(response["modelProvider"], "persisted-provider");
        assert_eq!(response["reasoningEffort"], "ultra");
        assert_eq!(response["cwd"], "/workspace");
    }

    #[test]
    fn explicit_model_group_never_leaks_persisted_reasoning_effort() {
        let params: ThreadResumeParams = serde_json::from_value(json!({
            "threadId": "00000000-0000-0000-0000-000000000002",
            "model": "new-model",
            "modelProvider": "new-provider",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandbox": "read-only"
        }))
        .unwrap();
        let settings = persisted_settings();

        let effective =
            EffectiveResumeSettings::resolve(&record(), Some(&settings), &params).unwrap();

        assert_eq!(effective.model, "new-model");
        assert_eq!(effective.model_provider, "new-provider");
        assert_eq!(effective.reasoning_effort, None);
    }

    #[test]
    fn explicit_model_identity_changes_require_a_complete_locally_resolvable_snapshot() {
        let settings = persisted_settings();
        for params in [
            json!({
                "threadId": "00000000-0000-0000-0000-000000000002",
                "model": "new-model"
            }),
            json!({
                "threadId": "00000000-0000-0000-0000-000000000002",
                "modelProvider": "new-provider"
            }),
        ] {
            let params: ThreadResumeParams = serde_json::from_value(params).unwrap();
            assert!(matches!(
                EffectiveResumeSettings::resolve(&record(), Some(&settings), &params),
                Err(CoreError::InvalidArgument)
            ));
        }
    }

    #[test]
    fn reasoning_only_override_reuses_persisted_model_identity() {
        let params: ThreadResumeParams = serde_json::from_value(json!({
            "threadId": "00000000-0000-0000-0000-000000000002",
            "config": {"model_reasoning_effort": "high"}
        }))
        .unwrap();
        let settings = persisted_settings();

        let effective =
            EffectiveResumeSettings::resolve(&record(), Some(&settings), &params).unwrap();

        assert_eq!(effective.model, "persisted-model");
        assert_eq!(effective.model_provider, "persisted-provider");
        assert_eq!(effective.reasoning_effort.as_deref(), Some("high"));
    }

    #[test]
    fn explicit_model_group_uses_the_explicit_config_reasoning_effort() {
        let params: ThreadResumeParams = serde_json::from_value(json!({
            "threadId": "00000000-0000-0000-0000-000000000002",
            "model": "new-model",
            "modelProvider": "new-provider",
            "config": {"model_reasoning_effort": "high"}
        }))
        .unwrap();
        let settings = persisted_settings();

        let effective =
            EffectiveResumeSettings::resolve(&record(), Some(&settings), &params).unwrap();

        assert_eq!(effective.model, "new-model");
        assert_eq!(effective.model_provider, "new-provider");
        assert_eq!(effective.reasoning_effort.as_deref(), Some("high"));
    }
}
