use super::thread_settings;
use crate::CoreError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

const MAX_USER_INPUT_TEXT_CHARS: usize = 1_048_576;

#[derive(Clone)]
pub(super) struct StartedTurn {
    thread_id: String,
    user_item: Option<UserMessage>,
    raw_params: Value,
}

impl StartedTurn {
    pub(super) fn thread_id(&self) -> &str {
        &self.thread_id
    }

    pub(super) fn user_item_id(&self) -> Option<&str> {
        self.user_item.as_ref().map(|item| item.id.as_str())
    }

    pub(super) fn raw_params(&self) -> &Value {
        &self.raw_params
    }
}

pub(super) fn prepare(
    known_thread_ids: &HashSet<String>,
    params: &Value,
    turn_id: String,
    user_item_id: String,
) -> Result<(StartedTurn, Vec<u8>), CoreError> {
    let mut raw_params = params
        .as_object()
        .cloned()
        .ok_or(CoreError::InvalidArgument)?;
    let params: TurnStartParams =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    let thread_id = thread_settings::canonical_thread_id(known_thread_ids, &params.thread_id)?;
    raw_params.insert("threadId".to_owned(), Value::String(thread_id.clone()));
    if let Some(cwd) = params.cwd.as_deref() {
        raw_params.insert(
            "cwd".to_owned(),
            Value::String(thread_settings::resolve_request_cwd(cwd)?),
        );
    }
    if let Some(roots) = params.runtime_workspace_roots.as_ref() {
        let roots = roots
            .iter()
            .map(|path| thread_settings::resolve_request_cwd(path))
            .collect::<Result<Vec<_>, _>>()?;
        raw_params.insert(
            "runtimeWorkspaceRoots".to_owned(),
            serde_json::to_value(roots).map_err(|_| CoreError::InvalidJson)?,
        );
    }
    if params.permissions.is_some() && params.sandbox_policy.is_some() {
        return Err(CoreError::InvalidArgument);
    }
    if params
        .environments
        .as_ref()
        .is_some_and(|values| values.iter().any(|value| !value.is_object()))
    {
        return Err(CoreError::InvalidArgument);
    }

    let text_chars = params.input.iter().try_fold(0_usize, |total, input| {
        total
            .checked_add(input.text_char_count())
            .ok_or(CoreError::InvalidArgument)
    })?;
    if text_chars > MAX_USER_INPUT_TEXT_CHARS {
        return Err(CoreError::InvalidArgument);
    }
    if params
        .model
        .as_deref()
        .is_some_and(|model| model.trim().is_empty())
        || params
            .service_tier
            .as_deref()
            .is_some_and(|tier| tier.trim().is_empty())
        || params
            .effort
            .as_deref()
            .is_some_and(|effort| effort.is_empty())
    {
        return Err(CoreError::InvalidArgument);
    }
    if params
        .sandbox_policy
        .as_ref()
        .is_some_and(|policy| !policy.is_valid())
    {
        return Err(CoreError::InvalidArgument);
    }

    let raw_params = Value::Object(raw_params);
    let raw_input = raw_params
        .get("input")
        .and_then(Value::as_array)
        .cloned()
        .ok_or(CoreError::InvalidArgument)?;
    let user_item = (!params.input.is_empty()).then_some(UserMessage {
        kind: UserMessageKind::UserMessage,
        id: user_item_id,
        client_id: params.client_user_message_id,
        content: raw_input,
    });
    let response = serde_json::to_vec(&TurnStartResponse {
        turn: InitialTurn {
            id: turn_id.clone(),
            items: Vec::new(),
            items_view: TurnItemsView::NotLoaded,
            status: TurnStatus::InProgress,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        },
    })
    .map_err(|_| CoreError::InvalidJson)?;

    Ok((
        StartedTurn {
            thread_id,
            user_item,
            raw_params,
        },
        response,
    ))
}

pub(super) fn project_started_user_items(
    response: Vec<u8>,
    started_turns: &HashMap<String, StartedTurn>,
    turn_states: &HashMap<String, super::TurnWire>,
) -> Result<Vec<u8>, CoreError> {
    if started_turns.is_empty() {
        return Ok(response);
    }
    let mut response: Value =
        serde_json::from_slice(&response).map_err(|_| CoreError::InvalidJson)?;
    let Some(thread) = response.get_mut("thread").and_then(Value::as_object_mut) else {
        return Err(CoreError::InvalidJson);
    };
    let thread_id = thread
        .get("id")
        .and_then(Value::as_str)
        .ok_or(CoreError::InvalidJson)?
        .to_owned();
    let has_in_progress_started_turn = started_turns.iter().any(|(turn_id, started)| {
        started.thread_id() == thread_id
            && turn_states
                .get(turn_id)
                .is_some_and(|turn| turn.status == super::TurnStatusWire::Running)
    });
    let Some(turns) = thread.get_mut("turns").and_then(Value::as_array_mut) else {
        return Err(CoreError::InvalidJson);
    };

    for turn in turns {
        let Some(turn_id) = turn.get("id").and_then(Value::as_str) else {
            return Err(CoreError::InvalidJson);
        };
        let Some(started) = started_turns
            .get(turn_id)
            .filter(|started| started.thread_id() == thread_id)
        else {
            continue;
        };
        turn.as_object_mut()
            .ok_or(CoreError::InvalidJson)?
            .insert("itemsView".to_owned(), Value::String("summary".to_owned()));
        if let Some(user_item) = &started.user_item {
            let items = turn
                .get_mut("items")
                .and_then(Value::as_array_mut)
                .ok_or(CoreError::InvalidJson)?;
            items.insert(
                0,
                serde_json::to_value(user_item).map_err(|_| CoreError::InvalidJson)?,
            );
        }
    }
    if has_in_progress_started_turn {
        thread.insert(
            "status".to_owned(),
            serde_json::json!({"type": "active", "activeFlags": []}),
        );
    }

    serde_json::to_vec(&response).map_err(|_| CoreError::InvalidJson)
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TurnStartParams {
    thread_id: String,
    #[serde(default)]
    client_user_message_id: Option<String>,
    input: Vec<UserInput>,
    #[serde(default, rename = "attachments")]
    _attachments: Option<Vec<Value>>,
    #[serde(default)]
    responsesapi_client_metadata: Option<HashMap<String, String>>,
    #[serde(default)]
    additional_context: Option<HashMap<String, AdditionalContextEntry>>,
    #[serde(default)]
    environments: Option<Vec<Value>>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    runtime_workspace_roots: Option<Vec<String>>,
    #[serde(default)]
    dynamic_tools: Option<Vec<Value>>,
    #[serde(default)]
    selected_capability_roots: Option<Vec<Value>>,
    #[serde(default)]
    approval_policy: Option<AskForApproval>,
    #[serde(default)]
    approvals_reviewer: Option<ApprovalsReviewer>,
    #[serde(default)]
    sandbox_policy: Option<SandboxPolicy>,
    #[serde(default)]
    permissions: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    service_tier: Option<String>,
    #[serde(default)]
    effort: Option<String>,
    #[serde(default)]
    summary: Option<ReasoningSummary>,
    #[serde(default, rename = "collaborationMode")]
    _collaboration_mode: Option<Value>,
    #[serde(default, rename = "multiAgentMode")]
    _multi_agent_mode: Option<Value>,
    #[serde(default)]
    personality: Option<Personality>,
    #[serde(default)]
    output_schema: Option<Value>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AdditionalContextEntry {
    value: String,
    kind: AdditionalContextKind,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum AdditionalContextKind {
    User,
    Application,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", deny_unknown_fields)]
enum UserInput {
    Text {
        text: String,
        #[serde(default)]
        text_elements: Vec<TextElement>,
    },
    Image {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<ImageDetail>,
        url: String,
    },
    LocalImage {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<ImageDetail>,
        path: String,
    },
    Audio {
        url: String,
    },
    LocalAudio {
        path: String,
    },
    Skill {
        name: String,
        path: String,
    },
    Mention {
        name: String,
        path: String,
    },
}

impl UserInput {
    fn text_char_count(&self) -> usize {
        match self {
            Self::Text { text, .. } => text.chars().count(),
            Self::Image { .. }
            | Self::LocalImage { .. }
            | Self::Audio { .. }
            | Self::LocalAudio { .. }
            | Self::Skill { .. }
            | Self::Mention { .. } => 0,
        }
    }
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum ImageDetail {
    Auto,
    Low,
    High,
    Original,
}

#[derive(Deserialize, Serialize)]
#[serde(untagged)]
enum AskForApproval {
    Mode(ApprovalMode),
    Granular(GranularAskForApproval),
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
enum ApprovalMode {
    Untrusted,
    OnRequest,
    Never,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct GranularAskForApproval {
    granular: GranularApproval,
}

#[derive(Deserialize, Serialize)]
struct GranularApproval {
    sandbox_approval: bool,
    rules: bool,
    #[serde(default)]
    skill_approval: bool,
    #[serde(default)]
    request_permissions: bool,
    mcp_elicitations: bool,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum ApprovalsReviewer {
    User,
    AutoReview,
    GuardianSubagent,
}

#[derive(Deserialize, Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum SandboxPolicy {
    DangerFullAccess {},
    ReadOnly {
        network_access: bool,
    },
    ExternalSandbox {
        network_access: NetworkAccess,
    },
    WorkspaceWrite {
        writable_roots: Vec<String>,
        network_access: bool,
        exclude_tmpdir_env_var: bool,
        exclude_slash_tmp: bool,
    },
}

impl SandboxPolicy {
    fn is_valid(&self) -> bool {
        match self {
            Self::DangerFullAccess {} => true,
            Self::ReadOnly { network_access } => {
                let _ = network_access;
                true
            }
            Self::ExternalSandbox { network_access } => {
                let _ = network_access;
                true
            }
            Self::WorkspaceWrite {
                writable_roots,
                network_access,
                exclude_tmpdir_env_var,
                exclude_slash_tmp,
            } => {
                let _ = (network_access, exclude_tmpdir_env_var, exclude_slash_tmp);
                writable_roots
                    .iter()
                    .all(|root| std::path::Path::new(root).is_absolute())
            }
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum NetworkAccess {
    Restricted,
    Enabled,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum ReasoningSummary {
    Auto,
    Concise,
    Detailed,
    None,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Personality {
    None,
    Friendly,
    Pragmatic,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TextElement {
    byte_range: ByteRange,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    placeholder: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ByteRange {
    start: usize,
    end: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnStartResponse {
    turn: InitialTurn,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitialTurn {
    id: String,
    items: Vec<Value>,
    items_view: TurnItemsView,
    status: TurnStatus,
    error: Option<Value>,
    started_at: Option<i64>,
    completed_at: Option<i64>,
    duration_ms: Option<i64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum TurnItemsView {
    NotLoaded,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum TurnStatus {
    InProgress,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct UserMessage {
    #[serde(rename = "type")]
    kind: UserMessageKind,
    id: String,
    #[serde(rename = "clientId")]
    client_id: Option<String>,
    content: Vec<Value>,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum UserMessageKind {
    UserMessage,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sandbox_policy_requires_the_complete_stable_variant_shape() {
        for sandbox_policy in [
            serde_json::json!({"type": "readOnly"}),
            serde_json::json!({"type": "externalSandbox"}),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["/workspace"],
                "networkAccess": true,
                "excludeTmpdirEnvVar": false,
            }),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["relative/path"],
                "networkAccess": true,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            }),
            serde_json::json!({
                "type": "dangerFullAccess",
                "networkAccess": true,
            }),
        ] {
            let result = prepare_with_sandbox(sandbox_policy.clone());
            assert!(
                matches!(result, Err(CoreError::InvalidArgument)),
                "accepted invalid sandbox policy: {sandbox_policy}"
            );
        }
    }

    #[test]
    fn sandbox_policy_accepts_each_complete_stable_variant() {
        for sandbox_policy in [
            serde_json::json!({"type": "dangerFullAccess"}),
            serde_json::json!({"type": "readOnly", "networkAccess": false}),
            serde_json::json!({
                "type": "externalSandbox",
                "networkAccess": "restricted",
            }),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["/workspace", "/tmp/output"],
                "networkAccess": true,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": true,
            }),
        ] {
            assert!(prepare_with_sandbox(sandbox_policy).is_ok());
        }
    }

    #[test]
    fn desktop_turn_start_accepts_and_preserves_attachment_metadata() {
        let attachments = serde_json::json!([
            {
                "label": "notes.txt",
                "path": "/workspace/.codex/attachments/notes.txt",
                "fsPath": "/workspace/.codex/attachments/notes.txt"
            }
        ]);
        let params = serde_json::json!({
            "threadId": "00000000-0000-0000-0000-000000000002",
            "input": [{"type": "text", "text": "Summarize the attachment"}],
            "attachments": attachments,
        });

        let (started, _) = prepare(
            &HashSet::from(["00000000-0000-0000-0000-000000000002".to_owned()]),
            &params,
            "00000000-0000-0000-0000-000000000003".to_owned(),
            "00000000-0000-0000-0000-000000000004".to_owned(),
        )
        .expect("desktop attachment metadata should remain wire-compatible");

        assert_eq!(started.raw_params()["attachments"], attachments);
    }

    fn prepare_with_sandbox(sandbox_policy: Value) -> Result<(StartedTurn, Vec<u8>), CoreError> {
        prepare(
            &HashSet::from(["00000000-0000-0000-0000-000000000002".to_owned()]),
            &serde_json::json!({
                "threadId": "00000000-0000-0000-0000-000000000002",
                "input": [],
                "sandboxPolicy": sandbox_policy,
            }),
            "00000000-0000-0000-0000-000000000003".to_owned(),
            "00000000-0000-0000-0000-000000000004".to_owned(),
        )
    }
}
