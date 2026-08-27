use super::CoreError;
use base64::Engine as _;
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::{HashMap, HashSet};

mod raw_history;
mod thread_directory;
mod thread_resume;
mod thread_settings;
mod turn_start;

use thread_directory::{ThreadCreateMetadata, ThreadRecord, ThreadTerminalStatus};

const AUTO_REVIEW_DENIED_ACTION_APPROVAL_DEVELOPER_PREFIX: &str =
    "The user has manually approved a specific action that was previously `Rejected`.";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum ThreadMemoryModeWire {
    Enabled,
    Disabled,
}

#[derive(Clone, Default)]
pub(crate) struct SessionIndex {
    workspace_ids: HashSet<String>,
    workspaces: HashMap<String, WorkspaceWire>,
    thread_ids: HashSet<String>,
    threads: HashMap<String, ThreadWire>,
    turn_threads: HashMap<String, String>,
    turns: HashMap<String, TurnWire>,
    turn_order: Vec<String>,
    completed_turn_ids: HashSet<String>,
    archived_thread_ids: HashSet<String>,
    item_ids: HashSet<String>,
    items: HashMap<String, ThreadItemWire>,
    item_order: Vec<String>,
    thread_goals: HashMap<String, ThreadGoalWire>,
    thread_settings: HashMap<String, serde_json::Value>,
    thread_records: HashMap<String, ThreadRecord>,
    stable_turn_starts: HashMap<String, turn_start::StartedTurn>,
    raw_history: raw_history::RawHistoryIndex,
    pending_shell_commands: HashMap<String, PendingShellCommand>,
    subscribed_thread_ids: HashSet<String>,
    queued_submissions: HashMap<String, Vec<QueuedSubmissionWire>>,
}

#[derive(Deserialize)]
struct WorkspaceOpenCommand {
    workspace: WorkspaceWire,
}

#[derive(Deserialize)]
struct WorkspaceIDCommand {
    #[serde(rename = "workspaceId")]
    workspace_id: String,
}

#[derive(Deserialize)]
struct ThreadStartCommand {
    thread: ThreadWire,
    #[serde(default)]
    metadata: Option<ThreadCreateMetadata>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StableThreadStartCommand {
    kind: String,
    #[serde(default)]
    workspace: Option<WorkspaceWire>,
    thread: ThreadWire,
    metadata: ThreadCreateMetadata,
    settings: serde_json::Value,
}

#[derive(Deserialize)]
struct ThreadSetNameCommand {
    #[serde(rename = "threadId")]
    thread_id: String,
    name: String,
}

#[derive(Deserialize)]
struct ThreadIDCommand {
    #[serde(rename = "threadId")]
    thread_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadRollbackCommand {
    thread_id: String,
    num_turns: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadRevertCommand {
    thread_id: String,
    before_turn_id: String,
}

#[derive(Deserialize)]
struct ThreadMetadataUpdateCommand {
    params: serde_json::Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ThreadMemoryModeSetParams {
    thread_id: String,
    mode: ThreadMemoryModeWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ThreadMemoryModeSetCommand {
    kind: String,
    thread_id: String,
    mode: ThreadMemoryModeWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadGoalSetCommand {
    thread_id: String,
    #[serde(default)]
    objective: PatchField<String>,
    #[serde(default)]
    status: PatchField<ThreadGoalStatusWire>,
    #[serde(default)]
    token_budget: PatchField<i64>,
}

#[derive(Clone, Default)]
enum PatchField<T> {
    #[default]
    Missing,
    Null,
    Value(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for PatchField<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            Some(value) => Self::Value(value),
            None => Self::Null,
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadForkCommand {
    thread_id: String,
    new_thread_id: String,
    title: String,
    last_turn_id: Option<String>,
    turn_id_map: HashMap<String, String>,
    item_id_map: HashMap<String, String>,
    #[serde(default)]
    settings_override: Option<serde_json::Value>,
    #[serde(default)]
    ephemeral: Option<bool>,
    #[serde(default)]
    thread_source: PatchField<String>,
    #[serde(default)]
    timestamp: Option<i64>,
}

#[derive(Deserialize)]
struct TurnStartCommand {
    turn: TurnWire,
    #[serde(rename = "userItem")]
    user_item: ThreadItemWire,
    #[serde(default)]
    timestamp: Option<i64>,
}

#[derive(Deserialize)]
struct TurnCompleteCommand {
    #[serde(rename = "turnId")]
    turn_id: String,
    #[serde(rename = "assistantItem")]
    assistant_item: ThreadItemWire,
    #[serde(default)]
    timestamp: Option<i64>,
}

#[derive(Deserialize)]
struct TurnFailCommand {
    #[serde(rename = "turnId")]
    turn_id: String,
    #[serde(rename = "errorItem")]
    error_item: ThreadItemWire,
    #[serde(default)]
    timestamp: Option<i64>,
}

#[derive(Deserialize)]
struct TurnCancelCommand {
    #[serde(rename = "turnId")]
    turn_id: String,
    #[serde(default)]
    timestamp: Option<i64>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct QueuedSubmissionWire {
    id: String,
    input: Vec<serde_json::Value>,
    client_user_message_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueueAddCommand {
    kind: String,
    thread_id: String,
    queued_submission: QueuedSubmissionWire,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueueUpdateCommand {
    kind: String,
    thread_id: String,
    queued_submission_id: String,
    input: Vec<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueueDeleteCommand {
    kind: String,
    thread_id: String,
    queued_submission_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueueReorderCommand {
    kind: String,
    thread_id: String,
    queued_submission_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct QueueStartCommand {
    kind: String,
    thread_id: String,
    queued_submission_id: String,
    turn_command: serde_json::Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadQueueChangedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    queued_submissions: &'a [QueuedSubmissionWire],
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StableTurnStartCommand {
    kind: String,
    thread_id: String,
    turn_id: String,
    user_item_id: String,
    params: serde_json::Value,
    #[serde(default)]
    settings_patch: Option<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StableCompactStartCommand {
    kind: String,
    thread_id: String,
    turn_id: String,
    item_id: String,
}

#[derive(Clone)]
struct PendingShellCommand {
    thread_id: String,
    turn_id: String,
    after_turn_id: Option<String>,
    command: String,
    cwd: String,
    standalone_turn: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShellCommandStartCommand {
    kind: String,
    command_id: String,
    thread_id: String,
    turn_id: String,
    #[serde(default)]
    after_turn_id: Option<String>,
    command: String,
    cwd: String,
    standalone_turn: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ShellCommandCompleteCommand {
    kind: String,
    command_id: String,
    exit_code: i64,
    duration_millis: u64,
    stdout: String,
    stderr: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadApproveGuardianDeniedActionParams {
    thread_id: String,
    event: serde_json::Value,
}

#[derive(Deserialize)]
struct ItemAppendCommand {
    item: ThreadItemWire,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceWire {
    id: String,
    display_name: String,
    root_bookmark_id: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadWire {
    id: String,
    workspace_id: String,
    title: String,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnWire {
    id: String,
    thread_id: String,
    status: TurnStatusWire,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum TurnStatusWire {
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadItemWire {
    id: String,
    thread_id: String,
    turn_id: String,
    kind: ThreadItemKindWire,
    text: String,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum ThreadItemKindWire {
    UserMessage,
    AssistantMessage,
    Reasoning,
    ToolCall,
    ToolResult,
    Approval,
    FileChange,
    Terminal,
    ContextCompaction,
    Error,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadGoalWire {
    thread_id: String,
    objective: String,
    status: ThreadGoalStatusWire,
    token_budget: Option<i64>,
    tokens_used: i64,
    time_used_seconds: i64,
    created_at: i64,
    updated_at: i64,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum ThreadGoalStatusWire {
    Active,
    Paused,
    Blocked,
    UsageLimited,
    BudgetLimited,
    Complete,
}

#[derive(Serialize)]
struct WorkspaceUpsertedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    workspace: &'a WorkspaceWire,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceRemovedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    workspace_id: &'a str,
}

#[derive(Serialize)]
struct ThreadUpsertedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread: &'a ThreadWire,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadNameUpdatedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    name: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadLifecycleEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadGoalUpdatedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    turn_id: Option<&'a str>,
    goal: &'a ThreadGoalWire,
}

#[derive(Serialize)]
struct TurnStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    turn: &'a TurnWire,
}

#[derive(Serialize)]
struct ItemAppendedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    item: &'a ThreadItemWire,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TurnStatusChangedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    turn_id: &'a str,
    status: TurnStatusWire,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StableTurnStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    turn_id: &'a str,
    user_item_id: &'a str,
    params: &'a serde_json::Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StableCompactStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    turn_id: &'a str,
    item_id: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ShellCommandStartedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    command_id: &'a str,
    thread_id: &'a str,
    turn_id: &'a str,
    command: &'a str,
    cwd: &'a str,
    standalone_turn: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ShellCommandCompletedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    command_id: &'a str,
    thread_id: &'a str,
    turn_id: &'a str,
    command: &'a str,
    cwd: &'a str,
    exit_code: i64,
    duration_millis: u64,
    stdout: &'a str,
    stderr: &'a str,
    standalone_turn: bool,
}

impl SessionIndex {
    pub(crate) fn subscribe_thread(&mut self, thread_id: &str) -> Result<(), CoreError> {
        if !self.thread_ids.contains(thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        self.subscribed_thread_ids.insert(thread_id.to_owned());
        Ok(())
    }

    pub(crate) fn unsubscribe_thread(
        &mut self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let fields = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if fields.len() != 1 {
            return Err(CoreError::InvalidArgument);
        }
        let thread_id = fields
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or(CoreError::InvalidArgument)?;
        let status = if !self.thread_ids.contains(thread_id) {
            "notLoaded"
        } else if self.subscribed_thread_ids.remove(thread_id) {
            "unsubscribed"
        } else {
            "notSubscribed"
        };
        serde_json::to_vec(&serde_json::json!({"status": status}))
            .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn loaded_threads(&self, params: &serde_json::Value) -> Result<Vec<u8>, CoreError> {
        let fields = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if !fields.keys().all(|key| key == "cursor" || key == "limit") {
            return Err(CoreError::InvalidArgument);
        }
        let cursor = match fields.get("cursor") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            _ => return Err(CoreError::InvalidArgument),
        };
        let limit = match fields.get("limit") {
            None | Some(serde_json::Value::Null) => usize::MAX,
            Some(value) => value
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .filter(|value| *value > 0)
                .ok_or(CoreError::InvalidArgument)?,
        };
        let mut ids: Vec<_> = self.subscribed_thread_ids.iter().cloned().collect();
        ids.sort();
        let start = match cursor {
            None => 0,
            Some(cursor) => ids
                .iter()
                .position(|thread_id| thread_id == cursor)
                .map(|index| index + 1)
                .ok_or(CoreError::InvalidArgument)?,
        };
        let end = ids.len().min(start.saturating_add(limit));
        let data = ids[start..end].to_vec();
        let next_cursor = (end < ids.len()).then(|| data.last().cloned()).flatten();
        serde_json::to_vec(&serde_json::json!({
            "data": data,
            "nextCursor": next_cursor,
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn prepare_request_shell_command(
        &self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if object.len() != 2 {
            return Err(CoreError::InvalidArgument);
        }
        let requested_thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?;
        let thread_id =
            thread_settings::canonical_thread_id(&self.thread_ids, requested_thread_id)?;
        let command = object
            .get("command")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|command| !command.is_empty() && !command.contains('\0'))
            .ok_or(CoreError::InvalidArgument)?
            .to_owned();
        let cwd = self
            .thread_records
            .get(&thread_id)
            .filter(|record| record.has_official_metadata())
            .map(|record| record.cwd().to_owned())
            .filter(|cwd| std::path::Path::new(cwd).is_absolute())
            .ok_or(CoreError::InvalidArgument)?;
        let running_turn = self.turn_order.iter().rev().find(|turn_id| {
            self.turns.get(*turn_id).is_some_and(|turn| {
                turn.thread_id == thread_id && turn.status == TurnStatusWire::Running
            })
        });
        let standalone_turn = running_turn.is_none();
        let turn_id = running_turn
            .cloned()
            .unwrap_or_else(|| self.generate_unique_uuid_v7());
        let after_turn_id = self.turn_order.iter().rev().find(|candidate| {
            **candidate != turn_id
                && self.turns.get(*candidate).is_some_and(|turn| {
                    turn.thread_id == thread_id && turn.status == TurnStatusWire::Completed
                })
        });
        let command_id = loop {
            let candidate = self.generate_unique_uuid_v7();
            if candidate != turn_id && !self.pending_shell_commands.contains_key(&candidate) {
                break candidate;
            }
        };
        serde_json::to_vec(&serde_json::json!({
            "kind": "thread.shell-command.start",
            "commandId": command_id,
            "threadId": thread_id,
            "turnId": turn_id,
            "afterTurnId": after_turn_id,
            "command": command,
            "cwd": cwd,
            "standaloneTurn": standalone_turn,
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn prepare_request_inject_items(
        &self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if object.len() != 2 {
            return Err(CoreError::InvalidArgument);
        }
        let requested_thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?;
        let thread_id =
            thread_settings::canonical_thread_id(&self.thread_ids, requested_thread_id)?;
        if self
            .turns
            .values()
            .any(|turn| turn.thread_id == thread_id && turn.status == TurnStatusWire::Running)
        {
            return Err(CoreError::InvalidArgument);
        }
        let items = object
            .get("items")
            .and_then(serde_json::Value::as_array)
            .filter(|items| !items.is_empty())
            .ok_or(CoreError::InvalidArgument)?;
        let mut encoded_items = Vec::with_capacity(items.len());
        for item in items {
            if !item.is_object() {
                return Err(CoreError::InvalidArgument);
            }
            let parsed: codex_protocol::models::ResponseItem =
                serde_json::from_value(item.clone()).map_err(|_| CoreError::InvalidArgument)?;
            if matches!(parsed, codex_protocol::models::ResponseItem::Other) {
                return Err(CoreError::InvalidArgument);
            }
            encoded_items.push(serde_json::to_string(item).map_err(|_| CoreError::InvalidJson)?);
        }
        let after_turn_id = self.turn_order.iter().rev().find(|turn_id| {
            self.turns
                .get(*turn_id)
                .is_some_and(|turn| turn.thread_id == thread_id)
        });
        serde_json::to_vec(&serde_json::json!({
            "kind": "thread.inject-items",
            "threadId": thread_id,
            "afterTurnId": after_turn_id,
            "items": encoded_items,
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn prepare_request_approve_guardian_denied_action(
        &self,
        params: &serde_json::Value,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        let params: ThreadApproveGuardianDeniedActionParams =
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
        let thread_id = thread_settings::canonical_thread_id(&self.thread_ids, &params.thread_id)?;
        let event: codex_protocol::protocol::GuardianAssessmentEvent =
            serde_json::from_value(params.event).map_err(|_| CoreError::InvalidArgument)?;
        if event.status != codex_protocol::protocol::GuardianAssessmentStatus::Denied {
            return Ok(None);
        }

        let approved_action = serde_json::json!({
            "action": &event.action,
            "outcome": "allowed",
        });
        let approved_action_json =
            serde_json::to_string_pretty(&approved_action).map_err(|_| CoreError::InvalidJson)?;
        let text = format!(
            "{AUTO_REVIEW_DENIED_ACTION_APPROVAL_DEVELOPER_PREFIX}\n\n\
             Treat this as approval to perform that exact action in the same context in which it was originally requested.\n\
             Do not assume this also authorizes similar operations with different payloads.\n\n\
             Approved action:\n{approved_action_json}"
        );
        let item = serde_json::json!({
            "type": "message",
            "role": "developer",
            "content": [{
                "type": "input_text",
                "text": text,
            }],
        });
        let item_json = serde_json::to_string(&item).map_err(|_| CoreError::InvalidJson)?;
        let after_turn_id = self.turn_order.iter().rev().find(|turn_id| {
            self.turns
                .get(*turn_id)
                .is_some_and(|turn| turn.thread_id == thread_id)
        });
        serde_json::to_vec(&serde_json::json!({
            "kind": "thread.inject-items",
            "threadId": thread_id,
            "afterTurnId": after_turn_id,
            "items": [item_json],
        }))
        .map(Some)
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn request(
        &self,
        method: &str,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        match method {
            "thread/list" => {
                thread_directory::list(&self.thread_records, &self.archived_thread_ids, params)
            }
            "thread/read" => raw_history::make_thread_read_truthful(
                turn_start::project_started_user_items(
                    thread_directory::read(
                        &self.thread_records,
                        &self.turn_order,
                        &self.turns,
                        &self.item_order,
                        &self.items,
                        params,
                    )?,
                    &self.stable_turn_starts,
                    &self.turns,
                )?,
                &self.raw_history,
            ),
            "thread/prior-input-items" => self.raw_history.prior_input_items(
                &self.thread_ids,
                &self.turn_order,
                &self.turns,
                &self.stable_turn_starts,
                params,
            ),
            "thread/resume" => raw_history::make_thread_read_truthful(
                turn_start::project_started_user_items(
                    thread_resume::resume(
                        &self.thread_records,
                        &self.thread_settings,
                        &self.turn_order,
                        &self.turns,
                        &self.item_order,
                        &self.items,
                        params,
                    )?,
                    &self.stable_turn_starts,
                    &self.turns,
                )?,
                &self.raw_history,
            ),
            "thread/search" => {
                let mut visible_content: HashMap<String, Vec<String>> = HashMap::new();
                for item_id in &self.item_order {
                    let Some(item) = self.items.get(item_id) else {
                        continue;
                    };
                    if matches!(
                        item.kind,
                        ThreadItemKindWire::UserMessage | ThreadItemKindWire::AssistantMessage
                    ) {
                        visible_content
                            .entry(item.thread_id.clone())
                            .or_default()
                            .push(item.text.clone());
                    }
                }
                thread_directory::search(
                    &self.thread_records,
                    &self.archived_thread_ids,
                    &visible_content,
                    params,
                )
            }
            _ => Err(CoreError::UnsupportedCommand),
        }
    }

    pub(crate) fn prepare_request_memory_mode_set(
        &self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let mut params: ThreadMemoryModeSetParams =
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
        params.thread_id =
            thread_settings::canonical_thread_id(&self.thread_ids, &params.thread_id)?;
        serde_json::to_vec(&serde_json::json!({
            "kind": "thread.memory-mode-set",
            "threadId": params.thread_id,
            "mode": params.mode,
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn prepare_request_turn_start(
        &self,
        params: &serde_json::Value,
    ) -> Result<(Vec<u8>, Vec<u8>), CoreError> {
        let requested_thread_id = params
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?;
        let thread_id =
            thread_settings::canonical_thread_id(&self.thread_ids, requested_thread_id)?;
        let runtime = self
            .thread_records
            .get(&thread_id)
            .ok_or(CoreError::InvalidArgument)?
            .runtime();
        let mut params_with_runtime = params
            .as_object()
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        if params_with_runtime
            .get("runtimeWorkspaceRoots")
            .is_some_and(serde_json::Value::is_null)
        {
            params_with_runtime.remove("runtimeWorkspaceRoots");
        }
        if !params_with_runtime.contains_key("runtimeWorkspaceRoots") {
            if let Some(roots) = runtime.runtime_workspace_roots.as_ref() {
                params_with_runtime.insert(
                    "runtimeWorkspaceRoots".to_owned(),
                    serde_json::to_value(roots).map_err(|_| CoreError::InvalidJson)?,
                );
            }
        }
        if !params_with_runtime.contains_key("environments") {
            if let Some(environments) = runtime.environments.as_ref() {
                params_with_runtime.insert(
                    "environments".to_owned(),
                    serde_json::Value::Array(environments.clone()),
                );
            }
        }
        if !params_with_runtime.contains_key("dynamicTools") {
            if let Some(dynamic_tools) = runtime.dynamic_tools.as_ref() {
                params_with_runtime.insert(
                    "dynamicTools".to_owned(),
                    serde_json::Value::Array(dynamic_tools.clone()),
                );
            }
        }
        if !params_with_runtime.contains_key("selectedCapabilityRoots") {
            if let Some(selected_capability_roots) = runtime.selected_capability_roots.as_ref() {
                params_with_runtime.insert(
                    "selectedCapabilityRoots".to_owned(),
                    serde_json::Value::Array(selected_capability_roots.clone()),
                );
            }
        }
        let params_with_runtime = serde_json::Value::Object(params_with_runtime);
        let mut effective_params = thread_settings::merge_into_turn_params(
            &self.thread_ids,
            &self.thread_settings,
            &params_with_runtime,
        )?;
        let prepared_settings = thread_settings::prepare_turn_patch(
            &self.thread_ids,
            &self.thread_records,
            &self.thread_settings,
            params,
        )?;
        if let Some(settings) = prepared_settings.effective.as_ref() {
            effective_params = thread_settings::merge_effective_settings_into_turn_params(
                &effective_params,
                settings,
            )?;
        }
        let turn_id = self.generate_unique_uuid_v7();
        let user_item_id = loop {
            let candidate = self.generate_unique_uuid_v7();
            if candidate != turn_id {
                break candidate;
            }
        };
        let (started_turn, response) = turn_start::prepare(
            &self.thread_ids,
            &effective_params,
            turn_id.clone(),
            user_item_id.clone(),
        )?;
        let persisted_params = started_turn.raw_params().clone();
        let command = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.stable-start",
            "threadId": started_turn.thread_id(),
            "turnId": turn_id,
            "userItemId": user_item_id,
            "params": persisted_params,
            "settingsPatch": prepared_settings.command,
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        Ok((command, response))
    }

    pub(crate) fn prepare_request_compact_start(
        &self,
        params: &serde_json::Value,
    ) -> Result<Vec<u8>, CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if object.len() != 1 {
            return Err(CoreError::InvalidArgument);
        }
        let requested_thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?;
        let thread_id =
            thread_settings::canonical_thread_id(&self.thread_ids, requested_thread_id)?;
        if self
            .turns
            .values()
            .any(|turn| turn.thread_id == thread_id && turn.status == TurnStatusWire::Running)
        {
            return Err(CoreError::InvalidArgument);
        }
        let turn_id = self.generate_unique_uuid_v7();
        let item_id = loop {
            let candidate = self.generate_unique_uuid_v7();
            if candidate != turn_id {
                break candidate;
            }
        };
        serde_json::to_vec(&serde_json::json!({
            "kind": "thread.compact-start",
            "threadId": thread_id,
            "turnId": turn_id,
            "itemId": item_id,
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn prepare_thread_settings_update(
        &self,
        params: &serde_json::Value,
    ) -> Result<Option<Vec<u8>>, CoreError> {
        thread_settings::prepare_rpc_command(
            &self.thread_ids,
            &self.thread_records,
            &self.thread_settings,
            params,
        )
    }

    pub(crate) fn prepare_request_thread_fork(
        &self,
        params: &serde_json::Value,
    ) -> Result<(Vec<u8>, String, bool), CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        const ALLOWED: &[&str] = &[
            "threadId",
            "lastTurnId",
            "path",
            "model",
            "modelProvider",
            "serviceTier",
            "cwd",
            "approvalPolicy",
            "approvalsReviewer",
            "sandbox",
            "config",
            "baseInstructions",
            "developerInstructions",
            "ephemeral",
            "threadSource",
            "excludeTurns",
        ];
        if object.keys().any(|key| !ALLOWED.contains(&key.as_str())) {
            return Err(CoreError::InvalidArgument);
        }
        let requested_thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?;
        let requested_path = match object.get("path") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(path)) if path.is_empty() => None,
            Some(serde_json::Value::String(path)) => Some(path.as_str()),
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let thread_id = if let Some(requested_path) = requested_path {
            let mut matching_records = self.thread_records.values().filter(|record| {
                record.has_official_metadata() && record.path() == Some(requested_path)
            });
            let thread_id = matching_records
                .next()
                .map(ThreadRecord::thread_id)
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            if matching_records.next().is_some() {
                return Err(CoreError::InvalidArgument);
            }
            thread_id
        } else {
            thread_settings::canonical_thread_id(&self.thread_ids, requested_thread_id)?
        };
        let source_record = self
            .thread_records
            .get(&thread_id)
            .filter(|record| record.has_official_metadata())
            .ok_or(CoreError::InvalidArgument)?;
        let last_turn_id = match object.get("lastTurnId") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value)) => {
                require_uuid(value)?;
                Some(value.clone())
            }
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let source_turn_ids: Vec<String> = self
            .turn_order
            .iter()
            .filter(|turn_id| {
                self.turns
                    .get(*turn_id)
                    .is_some_and(|turn| turn.thread_id == thread_id)
            })
            .cloned()
            .collect();
        let included_turn_ids = if let Some(last_turn_id) = last_turn_id.as_ref() {
            let index = source_turn_ids
                .iter()
                .position(|turn_id| turn_id == last_turn_id)
                .ok_or(CoreError::InvalidArgument)?;
            source_turn_ids[..=index].to_vec()
        } else {
            source_turn_ids
        };
        if included_turn_ids.iter().any(|turn_id| {
            self.turns
                .get(turn_id)
                .is_none_or(|turn| turn.status == TurnStatusWire::Running)
        }) {
            return Err(CoreError::InvalidArgument);
        }
        let included_turn_set: HashSet<&str> =
            included_turn_ids.iter().map(String::as_str).collect();
        let included_item_ids: Vec<String> = self
            .item_order
            .iter()
            .filter(|item_id| {
                self.items
                    .get(*item_id)
                    .is_some_and(|item| included_turn_set.contains(item.turn_id.as_str()))
            })
            .cloned()
            .collect();

        let settings_override = thread_resume::resolve_fork_settings(
            source_record,
            self.thread_settings.get(&thread_id),
            params,
        )?;
        let ephemeral = match object.get("ephemeral") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::Bool(value)) => Some(*value),
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let thread_source = match object.get("threadSource") {
            None => None,
            Some(serde_json::Value::Null) => Some(None),
            Some(serde_json::Value::String(value)) if !value.trim().is_empty() => {
                Some(Some(value.clone()))
            }
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let exclude_turns = match object.get("excludeTurns") {
            None | Some(serde_json::Value::Null) => false,
            Some(serde_json::Value::Bool(value)) => *value,
            Some(_) => return Err(CoreError::InvalidArgument),
        };

        let mut reserved = HashSet::new();
        let new_thread_id = self.generate_unique_uuid_v7();
        reserved.insert(new_thread_id.clone());
        let mut next_id = || loop {
            let candidate = self.generate_unique_uuid_v7();
            if reserved.insert(candidate.clone()) {
                break candidate;
            }
        };
        let turn_id_map: HashMap<String, String> = included_turn_ids
            .iter()
            .map(|source_id| (source_id.clone(), next_id()))
            .collect();
        let item_id_map: HashMap<String, String> = included_item_ids
            .iter()
            .map(|source_id| (source_id.clone(), next_id()))
            .collect();
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| CoreError::InvalidArgument)?
            .as_secs() as i64;
        let mut command = serde_json::json!({
            "kind": "thread.fork",
            "threadId": thread_id,
            "newThreadId": new_thread_id,
            "title": source_record.title(),
            "lastTurnId": last_turn_id,
            "turnIdMap": turn_id_map,
            "itemIdMap": item_id_map,
            "settingsOverride": settings_override,
            "ephemeral": ephemeral,
            "timestamp": timestamp,
        });
        if let Some(thread_source) = thread_source {
            command["threadSource"] = thread_source.map_or(serde_json::Value::Null, Into::into);
        }
        let command = serde_json::to_vec(&command).map_err(|_| CoreError::InvalidJson)?;
        Ok((command, new_thread_id, exclude_turns))
    }

    pub(crate) fn prepare_request_thread_start(
        &self,
        params: &serde_json::Value,
    ) -> Result<(Vec<u8>, String), CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        const ALLOWED: &[&str] = &[
            "model",
            "modelProvider",
            "allowProviderModelFallback",
            "serviceTier",
            "cwd",
            "runtimeWorkspaceRoots",
            "approvalPolicy",
            "approvalsReviewer",
            "sandbox",
            "permissions",
            "config",
            "serviceName",
            "baseInstructions",
            "developerInstructions",
            "personality",
            "mode",
            "multiAgentMode",
            "ephemeral",
            "historyMode",
            "sessionStartSource",
            "threadSource",
            "environments",
            "dynamicTools",
            "selectedCapabilityRoots",
            "mockExperimentalField",
            "experimentalRawEvents",
            "threadStartKind",
        ];
        if object.keys().any(|key| !ALLOWED.contains(&key.as_str())) {
            return Err(CoreError::InvalidArgument);
        }
        for field in [
            "serviceName",
            "baseInstructions",
            "developerInstructions",
            "mockExperimentalField",
        ] {
            if object
                .get(field)
                .is_some_and(|value| !value.is_null() && !value.is_string())
            {
                return Err(CoreError::InvalidArgument);
            }
        }
        for field in ["mode", "threadStartKind"] {
            if object.get(field).is_some_and(|value| {
                !value.is_null() && value.as_str().is_none_or(|value| value.trim().is_empty())
            }) {
                return Err(CoreError::InvalidArgument);
            }
        }
        for field in ["allowProviderModelFallback", "experimentalRawEvents"] {
            if object
                .get(field)
                .is_some_and(|value| !value.is_null() && !value.is_boolean())
            {
                return Err(CoreError::InvalidArgument);
            }
        }
        if object.get("permissions").is_some_and(|value| {
            !value.is_null()
                && value
                    .as_str()
                    .is_none_or(|profile| profile.trim().is_empty())
        }) || (object
            .get("permissions")
            .is_some_and(|value| !value.is_null())
            && object.get("sandbox").is_some_and(|value| !value.is_null()))
        {
            return Err(CoreError::InvalidArgument);
        }
        if object
            .get("config")
            .is_some_and(|value| !value.is_null() && !value.is_object())
        {
            return Err(CoreError::InvalidArgument);
        }
        let runtime_workspace_roots = match object.get("runtimeWorkspaceRoots") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::Array(values)) => values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .filter(|path| std::path::Path::new(path).is_absolute())
                        .map(str::to_owned)
                        .ok_or(CoreError::InvalidArgument)
                })
                .collect::<Result<Vec<_>, _>>()?
                .into(),
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let history_mode = match object.get("historyMode") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value))
                if matches!(value.as_str(), "legacy" | "paginated") =>
            {
                Some(value.clone())
            }
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let multi_agent_mode = match object.get("multiAgentMode") {
            None | Some(serde_json::Value::Null) => None,
            Some(value)
                if matches!(value.as_str(), Some("explicitRequestOnly" | "proactive"))
                    || value.as_object().is_some_and(|object| {
                        object.len() == 1
                            && object.get("custom").is_some_and(|v| {
                                v.as_str().is_some_and(|value| !value.trim().is_empty())
                            })
                    }) =>
            {
                Some(value.clone())
            }
            Some(_) => return Err(CoreError::InvalidArgument),
        };
        let array_of_objects = |field: &str| -> Result<Option<Vec<serde_json::Value>>, CoreError> {
            match object.get(field) {
                None | Some(serde_json::Value::Null) => Ok(None),
                Some(serde_json::Value::Array(values))
                    if values.iter().all(serde_json::Value::is_object) =>
                {
                    Ok(Some(values.clone()))
                }
                Some(_) => Err(CoreError::InvalidArgument),
            }
        };
        let environments = array_of_objects("environments")?;
        let dynamic_tools = array_of_objects("dynamicTools")?;
        let selected_capability_roots = array_of_objects("selectedCapabilityRoots")?;
        if let Some(value) = object.get("sessionStartSource") {
            match value {
                serde_json::Value::Null => {}
                serde_json::Value::String(value)
                    if matches!(value.as_str(), "startup" | "clear") => {}
                _ => return Err(CoreError::InvalidArgument),
            }
        }
        let cwd = object
            .get("cwd")
            .and_then(serde_json::Value::as_str)
            .filter(|cwd| std::path::Path::new(cwd).is_absolute())
            .ok_or(CoreError::InvalidArgument)?
            .to_owned();
        let model_provider = match object.get("modelProvider") {
            Some(serde_json::Value::String(value)) if !value.trim().is_empty() => value.clone(),
            None | Some(serde_json::Value::Null) => "openai".to_owned(),
            _ => return Err(CoreError::InvalidArgument),
        };
        let ephemeral = match object.get("ephemeral") {
            None | Some(serde_json::Value::Null) => false,
            Some(serde_json::Value::Bool(value)) => *value,
            _ => return Err(CoreError::InvalidArgument),
        };
        let thread_source = match object.get("threadSource") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value)) if !value.trim().is_empty() => {
                Some(value.clone())
            }
            _ => return Err(CoreError::InvalidArgument),
        };
        let mode = object
            .get("mode")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("default")
            .to_owned();
        let thread_start_kind = object
            .get("threadStartKind")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("default")
            .to_owned();
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| CoreError::InvalidArgument)?
            .as_secs() as i64;
        let thread_id = self.generate_unique_uuid_v7();
        let existing_workspace_id = self
            .thread_records
            .values()
            .find(|record| record.has_official_metadata() && record.cwd() == cwd)
            .map(|record| record.workspace_id().to_owned());
        let workspace = if existing_workspace_id.is_none() {
            let id = loop {
                let candidate = self.generate_unique_uuid_v7();
                if candidate != thread_id {
                    break candidate;
                }
            };
            let display_name = std::path::Path::new(&cwd)
                .file_name()
                .and_then(|name| name.to_str())
                .filter(|name| !name.trim().is_empty())
                .unwrap_or("Project")
                .to_owned();
            Some(WorkspaceWire {
                id,
                display_name,
                root_bookmark_id: None,
            })
        } else {
            None
        };
        let workspace_id = existing_workspace_id
            .or_else(|| workspace.as_ref().map(|workspace| workspace.id.clone()))
            .ok_or(CoreError::InvalidArgument)?;
        let title = "New thread".to_owned();
        let config = object
            .get("config")
            .and_then(serde_json::Value::as_object)
            .cloned()
            .unwrap_or_default();
        let metadata: ThreadCreateMetadata = serde_json::from_value(serde_json::json!({
            "sessionId": &thread_id,
            "preview": "",
            "ephemeral": ephemeral,
            "mode": mode,
            "modelProvider": model_provider,
            "threadStartKind": thread_start_kind,
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "recencyAt": timestamp,
            "path": null,
            "cwd": cwd,
            "cliVersion": env!("CARGO_PKG_VERSION"),
            "source": {"custom": "chatgpt"},
            "threadSource": thread_source,
            "parentThreadId": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null,
            "runtime": {
                "runtimeWorkspaceRoots": runtime_workspace_roots,
                "allowProviderModelFallback": object
                    .get("allowProviderModelFallback")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
                "config": config,
                "serviceName": object.get("serviceName").cloned().unwrap_or(serde_json::Value::Null),
                "baseInstructions": object.get("baseInstructions").cloned().unwrap_or(serde_json::Value::Null),
                "developerInstructions": object.get("developerInstructions").cloned().unwrap_or(serde_json::Value::Null),
                "historyMode": history_mode,
                "environments": environments,
                "dynamicTools": dynamic_tools,
                "selectedCapabilityRoots": selected_capability_roots,
                "mockExperimentalField": object.get("mockExperimentalField").cloned().unwrap_or(serde_json::Value::Null),
                "multiAgentMode": multi_agent_mode,
                "experimentalRawEvents": object
                    .get("experimentalRawEvents")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
            },
        }))
        .map_err(|_| CoreError::InvalidArgument)?;
        let provisional = ThreadRecord::from_metadata(
            thread_id.clone(),
            title.clone(),
            workspace_id.clone(),
            Some(metadata.clone()),
        )?;
        let settings = thread_settings::prepare_initial_settings(&provisional, &thread_id, params)?;
        let command = serde_json::to_vec(&serde_json::json!({
            "kind": "thread.stable-start",
            "workspace": workspace,
            "thread": {
                "id": &thread_id,
                "workspaceId": workspace_id,
                "title": title,
            },
            "metadata": metadata,
            "settings": settings,
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        Ok((command, thread_id))
    }

    #[cfg(test)]
    pub(crate) fn stable_turn_start_params(&self, turn_id: &str) -> Option<&serde_json::Value> {
        self.stable_turn_starts
            .get(turn_id)
            .map(turn_start::StartedTurn::raw_params)
    }

    pub(crate) fn stable_turn_thread_id(&self, turn_id: &str) -> Option<&str> {
        self.stable_turn_starts
            .get(turn_id)
            .map(turn_start::StartedTurn::thread_id)
    }

    #[cfg(test)]
    pub(crate) fn thread_memory_mode(&self, thread_id: &str) -> Option<ThreadMemoryModeWire> {
        self.thread_records
            .get(thread_id)
            .map(ThreadRecord::memory_mode)
    }

    pub(crate) fn submit(
        &mut self,
        kind: &str,
        input: &[u8],
        next_sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        match kind {
            "workspace.open" => self.open_workspace(input, next_sequence),
            "workspace.update" => self.update_workspace(input, next_sequence),
            "workspace.remove" => self.remove_workspace(input, next_sequence),
            "thread.start" => self.start_thread(input, next_sequence),
            "thread.stable-start" => self.start_stable_thread(input, next_sequence),
            "thread.set-name" => self.set_thread_name(input, next_sequence),
            "thread.archive" => self.archive_thread(input, next_sequence),
            "thread.unarchive" => self.unarchive_thread(input, next_sequence),
            "thread.delete" => self.delete_thread(input, next_sequence),
            "thread.fork" => self.fork_thread(input, next_sequence),
            "thread.rollback" => self.rollback_thread(input, next_sequence),
            "thread.revert" => self.revert_thread(input, next_sequence),
            "thread.queue.add" => self.queue_add(input, next_sequence),
            "thread.queue.update" => self.queue_update(input, next_sequence),
            "thread.queue.delete" => self.queue_delete(input, next_sequence),
            "thread.queue.reorder" => self.queue_reorder(input, next_sequence),
            "thread.queue.start" => self.queue_start(input, next_sequence),
            "thread.goal.set" => self.set_thread_goal(input, next_sequence),
            "thread.goal.clear" => self.clear_thread_goal(input, next_sequence),
            "thread.settings-update" => self.update_thread_settings(input, next_sequence),
            "thread.metadata-update" => self.update_thread_metadata(input, next_sequence),
            "thread.memory-mode-set" => self.set_thread_memory_mode(input, next_sequence),
            "turn.start" => self.start_turn(input, next_sequence),
            "turn.stable-start" => self.start_stable_turn(input, next_sequence),
            "thread.compact-start" => self.start_stable_compaction(input, next_sequence),
            "thread.shell-command.start" => self.start_shell_command(input, next_sequence),
            "thread.shell-command.complete" => self.complete_shell_command(input, next_sequence),
            "thread.inject-items" => {
                self.raw_history
                    .inject(&self.thread_ids, &self.turns, input, next_sequence)
            }
            "turn.raw-history.commit" => self.raw_history.commit(
                &self.turn_threads,
                &mut self.turns,
                &mut self.completed_turn_ids,
                input,
                next_sequence,
            ),
            "turn.compact-history.commit" => self.raw_history.commit_compaction(
                &self.turn_threads,
                &mut self.turns,
                &mut self.completed_turn_ids,
                &self.items,
                input,
                next_sequence,
            ),
            "item.append" => self.append_item(input, next_sequence),
            "turn.complete" => self.complete_turn(input, next_sequence),
            "turn.fail" => self.fail_turn(input, next_sequence),
            "turn.cancel" => self.cancel_turn(input, next_sequence),
            _ => Err(CoreError::UnsupportedCommand),
        }
    }

    pub(crate) fn queue_list(&self, params: &serde_json::Value) -> Result<Vec<u8>, CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if !object
            .keys()
            .all(|key| matches!(key.as_str(), "threadId" | "cursor" | "limit"))
        {
            return Err(CoreError::InvalidArgument);
        }
        let thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or(CoreError::InvalidArgument)?;
        self.require_queue_thread(thread_id)?;
        let cursor = match object.get("cursor") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            _ => return Err(CoreError::InvalidArgument),
        };
        let limit = match object.get("limit") {
            None | Some(serde_json::Value::Null) => usize::MAX,
            Some(value) => value
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .filter(|value| *value > 0)
                .ok_or(CoreError::InvalidArgument)?,
        };
        let entries = self
            .queued_submissions
            .get(thread_id)
            .cloned()
            .unwrap_or_default();
        let start = match cursor {
            None => 0,
            Some(cursor) => entries
                .iter()
                .position(|entry| entry.id == cursor)
                .map(|index| index + 1)
                .ok_or(CoreError::InvalidArgument)?,
        };
        let end = entries.len().min(start.saturating_add(limit));
        let data = entries[start..end].to_vec();
        let next_cursor = (end < entries.len())
            .then(|| data.last().map(|entry| entry.id.clone()))
            .flatten();
        serde_json::to_vec(&serde_json::json!({"data": data, "nextCursor": next_cursor}))
            .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn queue_submission(
        &self,
        thread_id: &str,
        submission_id: &str,
    ) -> Result<Vec<u8>, CoreError> {
        let entries = self
            .queued_submissions
            .get(thread_id)
            .ok_or(CoreError::InvalidArgument)?;
        let entry = entries
            .iter()
            .find(|entry| entry.id == submission_id)
            .ok_or(CoreError::InvalidArgument)?;
        serde_json::to_vec(&serde_json::json!({"queuedSubmission": entry}))
            .map_err(|_| CoreError::InvalidJson)
    }

    pub(crate) fn new_queue_submission_id(&self) -> String {
        loop {
            let id = codex_protocol::ThreadId::new().to_string();
            if !self.contains_any_id(&id)
                && !self
                    .queued_submissions
                    .values()
                    .flatten()
                    .any(|entry| entry.id == id)
            {
                return id;
            }
        }
    }

    pub(crate) fn prepare_request_queue_start(
        &self,
        params: &serde_json::Value,
    ) -> Result<(Vec<u8>, Vec<u8>), CoreError> {
        let object = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if !matches!(object.len(), 1 | 2)
            || !object
                .keys()
                .all(|key| matches!(key.as_str(), "threadId" | "queuedSubmissionId"))
        {
            return Err(CoreError::InvalidArgument);
        }
        let thread_id = object
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or(CoreError::InvalidArgument)?;
        self.require_queue_thread(thread_id)?;
        if !self.subscribed_thread_ids.contains(thread_id)
            || self.has_active_or_pending_turn(thread_id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let requested_id = match object.get("queuedSubmissionId") {
            None | Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(value)) if !value.is_empty() => Some(value.as_str()),
            _ => return Err(CoreError::InvalidArgument),
        };
        let queued_submission = self
            .queued_submissions
            .get(thread_id)
            .and_then(|entries| {
                entries
                    .iter()
                    .find(|entry| requested_id.is_none_or(|id| entry.id == id))
            })
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let (turn_command, response) = self.prepare_request_turn_start(&serde_json::json!({
            "threadId": thread_id,
            "input": queued_submission.input,
            "clientUserMessageId": queued_submission.client_user_message_id,
        }))?;
        let turn_command: serde_json::Value =
            serde_json::from_slice(&turn_command).map_err(|_| CoreError::InvalidJson)?;
        let command = serde_json::to_vec(&serde_json::json!({
            "kind": "thread.queue.start",
            "threadId": thread_id,
            "queuedSubmissionId": queued_submission.id,
            "turnCommand": turn_command,
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        Ok((command, response))
    }

    fn require_queue_thread(&self, thread_id: &str) -> Result<(), CoreError> {
        require_uuid(thread_id)?;
        if !self.thread_ids.contains(thread_id)
            || self.archived_thread_ids.contains(thread_id)
            || self
                .thread_records
                .get(thread_id)
                .is_some_and(ThreadRecord::is_ephemeral)
        {
            return Err(CoreError::InvalidArgument);
        }
        Ok(())
    }

    fn has_active_or_pending_turn(&self, thread_id: &str) -> bool {
        self.turns
            .values()
            .any(|turn| turn.thread_id == thread_id && turn.status == TurnStatusWire::Running)
            || self
                .pending_shell_commands
                .values()
                .any(|pending| pending.thread_id == thread_id)
    }

    fn queue_changed(&self, thread_id: &str, sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let entries = self
            .queued_submissions
            .get(thread_id)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        Ok(vec![
            serde_json::to_vec(&ThreadQueueChangedEvent {
                sequence,
                kind: "threadQueueChanged",
                thread_id,
                queued_submissions: entries,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        ])
    }

    fn queue_add(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: QueueAddCommand = decode(input)?;
        if command.kind != "thread.queue.add" {
            return Err(CoreError::InvalidArgument);
        }
        self.require_queue_thread(&command.thread_id)?;
        require_uuid(&command.queued_submission.id)?;
        require_text(&command.queued_submission.client_user_message_id)?;
        if command.queued_submission.input.is_empty()
            || self.contains_any_id(&command.queued_submission.id)
            || self
                .queued_submissions
                .values()
                .flatten()
                .any(|entry| entry.id == command.queued_submission.id)
        {
            return Err(CoreError::InvalidArgument);
        }
        self.queued_submissions
            .entry(command.thread_id.clone())
            .or_default()
            .push(command.queued_submission);
        self.queue_changed(&command.thread_id, sequence)
    }

    fn queue_update(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: QueueUpdateCommand = decode(input)?;
        if command.kind != "thread.queue.update" || command.input.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        self.require_queue_thread(&command.thread_id)?;
        let entries = self
            .queued_submissions
            .get_mut(&command.thread_id)
            .ok_or(CoreError::InvalidArgument)?;
        let entry = entries
            .iter_mut()
            .find(|entry| entry.id == command.queued_submission_id)
            .ok_or(CoreError::InvalidArgument)?;
        entry.input = command.input;
        self.queue_changed(&command.thread_id, sequence)
    }

    fn queue_delete(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: QueueDeleteCommand = decode(input)?;
        if command.kind != "thread.queue.delete" {
            return Err(CoreError::InvalidArgument);
        }
        self.require_queue_thread(&command.thread_id)?;
        let entries = self
            .queued_submissions
            .entry(command.thread_id.clone())
            .or_default();
        let before = entries.len();
        entries.retain(|entry| entry.id != command.queued_submission_id);
        if before == entries.len() {
            return Ok(Vec::new());
        }
        self.queue_changed(&command.thread_id, sequence)
    }

    fn queue_reorder(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: QueueReorderCommand = decode(input)?;
        if command.kind != "thread.queue.reorder" {
            return Err(CoreError::InvalidArgument);
        }
        self.require_queue_thread(&command.thread_id)?;
        let entries = self
            .queued_submissions
            .get_mut(&command.thread_id)
            .ok_or(CoreError::InvalidArgument)?;
        if command.queued_submission_ids.len() != entries.len()
            || command
                .queued_submission_ids
                .iter()
                .collect::<HashSet<_>>()
                .len()
                != entries.len()
            || command
                .queued_submission_ids
                .iter()
                .any(|id| !entries.iter().any(|entry| entry.id == *id))
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut by_id: HashMap<String, QueuedSubmissionWire> = entries
            .drain(..)
            .map(|entry| (entry.id.clone(), entry))
            .collect();
        *entries = command
            .queued_submission_ids
            .into_iter()
            .map(|id| by_id.remove(&id).ok_or(CoreError::InvalidArgument))
            .collect::<Result<Vec<_>, _>>()?;
        self.queue_changed(&command.thread_id, sequence)
    }

    fn queue_start(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: QueueStartCommand = decode(input)?;
        if command.kind != "thread.queue.start" {
            return Err(CoreError::InvalidArgument);
        }
        self.require_queue_thread(&command.thread_id)?;
        require_uuid(&command.queued_submission_id)?;
        if self.has_active_or_pending_turn(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let queued_submission = self
            .queued_submissions
            .get(&command.thread_id)
            .and_then(|entries| {
                entries
                    .iter()
                    .find(|entry| entry.id == command.queued_submission_id)
            })
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let turn_command = command
            .turn_command
            .as_object()
            .ok_or(CoreError::InvalidArgument)?;
        let turn_params = turn_command
            .get("params")
            .and_then(serde_json::Value::as_object)
            .ok_or(CoreError::InvalidArgument)?;
        if turn_command.get("kind").and_then(serde_json::Value::as_str) != Some("turn.stable-start")
            || turn_command
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .is_none_or(|thread_id| !thread_id.eq_ignore_ascii_case(&command.thread_id))
            || turn_params.get("input")
                != Some(&serde_json::Value::Array(queued_submission.input.clone()))
            || turn_params
                .get("clientUserMessageId")
                .and_then(serde_json::Value::as_str)
                != Some(queued_submission.client_user_message_id.as_str())
        {
            return Err(CoreError::InvalidArgument);
        }
        let encoded_turn_command =
            serde_json::to_vec(&command.turn_command).map_err(|_| CoreError::InvalidJson)?;
        let mut events = self.start_stable_turn(&encoded_turn_command, sequence)?;
        let entries = self
            .queued_submissions
            .get_mut(&command.thread_id)
            .ok_or(CoreError::InvalidArgument)?;
        let index = entries
            .iter()
            .position(|entry| entry.id == command.queued_submission_id)
            .ok_or(CoreError::InvalidArgument)?;
        entries.remove(index);
        events.extend(self.queue_changed(&command.thread_id, sequence + events.len() as u64)?);
        Ok(events)
    }

    fn start_shell_command(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ShellCommandStartCommand = decode(input)?;
        if command.kind != "thread.shell-command.start"
            || command.command_id.is_empty()
            || command.command.trim().is_empty()
            || command.command.contains('\0')
            || !std::path::Path::new(&command.cwd).is_absolute()
            || self
                .pending_shell_commands
                .contains_key(&command.command_id)
            || !self.thread_ids.contains(&command.thread_id)
            || command.after_turn_id.as_ref().is_some_and(|turn_id| {
                self.turns
                    .get(turn_id)
                    .is_none_or(|turn| turn.thread_id != command.thread_id)
            })
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut events = Vec::new();
        if command.standalone_turn {
            if self.turns.contains_key(&command.turn_id) {
                return Err(CoreError::InvalidArgument);
            }
            let turn = TurnWire {
                id: command.turn_id.clone(),
                thread_id: command.thread_id.clone(),
                status: TurnStatusWire::Running,
            };
            events.push(
                serde_json::to_vec(&TurnStartedEvent {
                    sequence,
                    kind: "turnStarted",
                    turn: &turn,
                })
                .map_err(|_| CoreError::InvalidJson)?,
            );
            self.turn_threads
                .insert(turn.id.clone(), turn.thread_id.clone());
            self.turn_order.push(turn.id.clone());
            self.turns.insert(turn.id.clone(), turn);
        } else if self.turns.get(&command.turn_id).is_none_or(|turn| {
            turn.thread_id != command.thread_id || turn.status != TurnStatusWire::Running
        }) {
            return Err(CoreError::InvalidArgument);
        }
        events.push(
            serde_json::to_vec(&ShellCommandStartedEvent {
                sequence,
                kind: "shellCommandStarted",
                command_id: &command.command_id,
                thread_id: &command.thread_id,
                turn_id: &command.turn_id,
                command: &command.command,
                cwd: &command.cwd,
                standalone_turn: command.standalone_turn,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        );
        self.pending_shell_commands.insert(
            command.command_id,
            PendingShellCommand {
                thread_id: command.thread_id,
                turn_id: command.turn_id,
                after_turn_id: command.after_turn_id,
                command: command.command,
                cwd: command.cwd,
                standalone_turn: command.standalone_turn,
            },
        );
        Ok(events)
    }

    fn complete_shell_command(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ShellCommandCompleteCommand = decode(input)?;
        if command.kind != "thread.shell-command.complete" || command.command_id.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        let pending = self
            .pending_shell_commands
            .remove(&command.command_id)
            .ok_or(CoreError::InvalidArgument)?;
        let aggregate = match (command.stdout.is_empty(), command.stderr.is_empty()) {
            (false, false) => format!("{}{}", command.stdout, command.stderr),
            (false, true) => command.stdout.clone(),
            (true, false) => command.stderr.clone(),
            (true, true) => String::new(),
        };
        let duration_seconds = command.duration_millis as f64 / 1000.0;
        let contextual_text = format!(
            "<user_shell_command>\n<command>\n{}\n</command>\n<result>\nExit code: {}\nDuration: {:.4} seconds\nOutput:\n{}\n</result>\n</user_shell_command>",
            pending.command, command.exit_code, duration_seconds, aggregate
        );
        let item = serde_json::to_string(&serde_json::json!({
            "type": "message",
            "role": "user",
            "content": [{
                "type": "input_text",
                "text": contextual_text,
            }],
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        let injection = serde_json::to_vec(&serde_json::json!({
            "kind": "thread.inject-items",
            "threadId": pending.thread_id,
            "afterTurnId": pending.after_turn_id,
            "items": [item],
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        let mut events =
            self.raw_history
                .inject(&self.thread_ids, &self.turns, &injection, sequence)?;
        if pending.standalone_turn {
            let turn = self
                .turns
                .get_mut(&pending.turn_id)
                .filter(|turn| turn.status == TurnStatusWire::Running)
                .ok_or(CoreError::InvalidArgument)?;
            turn.status = TurnStatusWire::Completed;
            self.completed_turn_ids.insert(pending.turn_id.clone());
            events.push(
                serde_json::to_vec(&TurnStatusChangedEvent {
                    sequence,
                    kind: "turnStatusChanged",
                    turn_id: &pending.turn_id,
                    status: TurnStatusWire::Completed,
                })
                .map_err(|_| CoreError::InvalidJson)?,
            );
        }
        events.push(
            serde_json::to_vec(&ShellCommandCompletedEvent {
                sequence,
                kind: "shellCommandCompleted",
                command_id: &command.command_id,
                thread_id: &pending.thread_id,
                turn_id: &pending.turn_id,
                command: &pending.command,
                cwd: &pending.cwd,
                exit_code: command.exit_code,
                duration_millis: command.duration_millis,
                stdout: &command.stdout,
                stderr: &command.stderr,
                standalone_turn: pending.standalone_turn,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        );
        Ok(events)
    }

    fn append_item(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ItemAppendCommand = decode(input)?;
        let item = command.item;
        require_uuid(&item.id)?;
        require_uuid(&item.thread_id)?;
        require_uuid(&item.turn_id)?;
        require_text(&item.text)?;
        let Some(thread_id) = self.turn_threads.get(&item.turn_id) else {
            return Err(CoreError::InvalidArgument);
        };
        let is_activity = matches!(
            item.kind,
            ThreadItemKindWire::Reasoning
                | ThreadItemKindWire::ToolCall
                | ThreadItemKindWire::ToolResult
                | ThreadItemKindWire::Approval
                | ThreadItemKindWire::FileChange
                | ThreadItemKindWire::Terminal
        );
        if !is_activity
            || &item.thread_id != thread_id
            || self.completed_turn_ids.contains(&item.turn_id)
            || self.contains_any_id(&item.id)
        {
            return Err(CoreError::InvalidArgument);
        }

        let events = encode_events([ItemAppendedEvent {
            sequence,
            kind: "itemAppended",
            item: &item,
        }])?;
        self.item_order.push(item.id.clone());
        self.item_ids.insert(item.id.clone());
        self.items.insert(item.id.clone(), item);
        Ok(events)
    }

    fn open_workspace(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: WorkspaceOpenCommand = decode(input)?;
        let workspace = command.workspace;
        require_uuid(&workspace.id)?;
        require_text(&workspace.display_name)?;
        if self.contains_any_id(&workspace.id) {
            return Err(CoreError::InvalidArgument);
        }

        let events = encode_events([WorkspaceUpsertedEvent {
            sequence,
            kind: "workspaceUpserted",
            workspace: &workspace,
        }])?;
        self.workspace_ids.insert(workspace.id.clone());
        self.workspaces.insert(workspace.id.clone(), workspace);
        Ok(events)
    }

    fn update_workspace(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: WorkspaceOpenCommand = decode(input)?;
        let workspace = command.workspace;
        require_uuid(&workspace.id)?;
        require_text(&workspace.display_name)?;
        if !self.workspace_ids.contains(&workspace.id) {
            return Err(CoreError::InvalidArgument);
        }

        let events = encode_events([WorkspaceUpsertedEvent {
            sequence,
            kind: "workspaceUpserted",
            workspace: &workspace,
        }])?;
        self.workspaces.insert(workspace.id.clone(), workspace);
        Ok(events)
    }

    fn remove_workspace(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: WorkspaceIDCommand = decode(input)?;
        require_uuid(&command.workspace_id)?;
        if !self.workspace_ids.contains(&command.workspace_id)
            || self
                .threads
                .values()
                .any(|thread| thread.workspace_id == command.workspace_id)
            || self
                .thread_records
                .values()
                .any(|record| record.workspace_id() == command.workspace_id)
        {
            return Err(CoreError::InvalidArgument);
        }

        let events = encode_events([WorkspaceRemovedEvent {
            sequence,
            kind: "workspaceRemoved",
            workspace_id: &command.workspace_id,
        }])?;
        self.workspace_ids.remove(&command.workspace_id);
        self.workspaces.remove(&command.workspace_id);
        Ok(events)
    }

    fn start_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadStartCommand = decode(input)?;
        let thread = command.thread;
        require_uuid(&thread.id)?;
        require_uuid(&thread.workspace_id)?;
        require_text(&thread.title)?;
        if self.contains_any_id(&thread.id) || !self.workspace_ids.contains(&thread.workspace_id) {
            return Err(CoreError::InvalidArgument);
        }
        let record = ThreadRecord::from_metadata(
            thread.id.clone(),
            thread.title.clone(),
            thread.workspace_id.clone(),
            command.metadata,
        )?;

        let events = encode_events([ThreadUpsertedEvent {
            sequence,
            kind: "threadUpserted",
            thread: &thread,
        }])?;
        self.thread_ids.insert(thread.id.clone());
        self.thread_records.insert(thread.id.clone(), record);
        self.threads.insert(thread.id.clone(), thread);
        Ok(events)
    }

    fn start_stable_thread(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: StableThreadStartCommand = decode(input)?;
        if command.kind != "thread.stable-start" || !command.settings.is_object() {
            return Err(CoreError::InvalidArgument);
        }
        let thread = command.thread;
        require_uuid(&thread.id)?;
        require_uuid(&thread.workspace_id)?;
        require_text(&thread.title)?;
        if self.contains_any_id(&thread.id) {
            return Err(CoreError::InvalidArgument);
        }
        let mut events = Vec::with_capacity(3);
        let mut next_sequence = sequence;
        if let Some(workspace) = command.workspace {
            require_uuid(&workspace.id)?;
            require_text(&workspace.display_name)?;
            if workspace.id != thread.workspace_id || self.contains_any_id(&workspace.id) {
                return Err(CoreError::InvalidArgument);
            }
            events.push(
                serde_json::to_vec(&WorkspaceUpsertedEvent {
                    sequence: next_sequence,
                    kind: "workspaceUpserted",
                    workspace: &workspace,
                })
                .map_err(|_| CoreError::InvalidJson)?,
            );
            next_sequence += 1;
            self.workspace_ids.insert(workspace.id.clone());
            self.workspaces.insert(workspace.id.clone(), workspace);
        } else if !self.workspace_ids.contains(&thread.workspace_id) {
            return Err(CoreError::InvalidArgument);
        }
        let mut record = ThreadRecord::from_metadata(
            thread.id.clone(),
            thread.title.clone(),
            thread.workspace_id.clone(),
            Some(command.metadata),
        )?;
        record.clear_name();
        events.push(
            serde_json::to_vec(&ThreadUpsertedEvent {
                sequence: next_sequence,
                kind: "threadUpserted",
                thread: &thread,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        );
        next_sequence += 1;
        events.push(
            serde_json::to_vec(&serde_json::json!({
                "sequence": next_sequence,
                "kind": "threadSettingsUpdated",
                "threadId": &thread.id,
                "threadSettings": &command.settings,
            }))
            .map_err(|_| CoreError::InvalidJson)?,
        );
        self.thread_ids.insert(thread.id.clone());
        self.thread_settings
            .insert(thread.id.clone(), command.settings);
        self.thread_records.insert(thread.id.clone(), record);
        self.threads.insert(thread.id.clone(), thread);
        Ok(events)
    }

    fn set_thread_name(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadSetNameCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        require_text(&command.name)?;
        if !self.thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let name = command.name.trim().to_owned();
        let events = encode_events([ThreadNameUpdatedEvent {
            sequence,
            kind: "threadNameUpdated",
            thread_id: &command.thread_id,
            name: &name,
        }])?;
        if let Some(thread) = self.threads.get_mut(&command.thread_id) {
            thread.title = name.clone();
        }
        self.thread_records
            .get_mut(&command.thread_id)
            .ok_or(CoreError::InvalidArgument)?
            .set_name(name)?;
        Ok(events)
    }

    fn archive_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadIDCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if !self.thread_ids.contains(&command.thread_id)
            || self.archived_thread_ids.contains(&command.thread_id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let events = encode_events([ThreadLifecycleEvent {
            sequence,
            kind: "threadArchived",
            thread_id: &command.thread_id,
        }])?;
        self.archived_thread_ids.insert(command.thread_id);
        Ok(events)
    }

    fn unarchive_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadIDCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if !self.archived_thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let events = encode_events([ThreadLifecycleEvent {
            sequence,
            kind: "threadUnarchived",
            thread_id: &command.thread_id,
        }])?;
        self.archived_thread_ids.remove(&command.thread_id);
        Ok(events)
    }

    fn set_thread_goal(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadGoalSetCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if !self.thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| CoreError::InvalidArgument)?
            .as_secs() as i64;
        let mut goal = self
            .thread_goals
            .get(&command.thread_id)
            .cloned()
            .unwrap_or(ThreadGoalWire {
                thread_id: command.thread_id.clone(),
                objective: String::new(),
                status: ThreadGoalStatusWire::Active,
                token_budget: None,
                tokens_used: 0,
                time_used_seconds: 0,
                created_at: now,
                updated_at: now,
            });
        if let PatchField::Value(objective) = command.objective {
            require_text(&objective)?;
            goal.objective = objective.trim().to_owned();
        }
        if let PatchField::Value(status) = command.status {
            goal.status = status;
        }
        match command.token_budget {
            PatchField::Missing => {}
            PatchField::Null => goal.token_budget = None,
            PatchField::Value(budget) if budget > 0 => goal.token_budget = Some(budget),
            PatchField::Value(_) => return Err(CoreError::InvalidArgument),
        }
        require_text(&goal.objective)?;
        goal.updated_at = now;
        let events = encode_events([ThreadGoalUpdatedEvent {
            sequence,
            kind: "threadGoalUpdated",
            thread_id: &goal.thread_id,
            turn_id: None,
            goal: &goal,
        }])?;
        self.thread_goals.insert(goal.thread_id.clone(), goal);
        Ok(events)
    }

    fn clear_thread_goal(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadIDCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if !self.thread_goals.contains_key(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let events = encode_events([ThreadLifecycleEvent {
            sequence,
            kind: "threadGoalCleared",
            thread_id: &command.thread_id,
        }])?;
        self.thread_goals.remove(&command.thread_id);
        Ok(events)
    }

    fn update_thread_settings(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        thread_settings::apply(
            &self.thread_ids,
            &self.thread_records,
            &mut self.thread_settings,
            input,
            sequence,
        )
    }

    fn update_thread_metadata(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadMetadataUpdateCommand = decode(input)?;
        let thread_id = command
            .params
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .ok_or(CoreError::InvalidArgument)?
            .to_owned();
        thread_directory::metadata_update(&mut self.thread_records, &command.params)?;
        let event = serde_json::to_vec(&serde_json::json!({
            "sequence": sequence,
            "kind": "threadMetadataChanged",
            "threadId": thread_id,
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        Ok(vec![event])
    }

    fn set_thread_memory_mode(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadMemoryModeSetCommand = decode(input)?;
        if command.kind != "thread.memory-mode-set" {
            return Err(CoreError::InvalidArgument);
        }
        let thread_id = thread_settings::canonical_thread_id(&self.thread_ids, &command.thread_id)?;
        let record = self
            .thread_records
            .get_mut(&thread_id)
            .ok_or(CoreError::InvalidArgument)?;
        record.set_memory_mode(command.mode);
        let event = serde_json::to_vec(&serde_json::json!({
            "sequence": sequence,
            "kind": "threadMemoryModeUpdated",
            "threadId": thread_id,
            "mode": command.mode,
        }))
        .map_err(|_| CoreError::InvalidJson)?;
        Ok(vec![event])
    }

    fn delete_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadIDCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if !self.thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let events = encode_events([ThreadLifecycleEvent {
            sequence,
            kind: "threadDeleted",
            thread_id: &command.thread_id,
        }])?;
        self.thread_ids.remove(&command.thread_id);
        self.thread_records.remove(&command.thread_id);
        self.threads.remove(&command.thread_id);
        self.archived_thread_ids.remove(&command.thread_id);
        let removed_turns: Vec<String> = self
            .turn_threads
            .iter()
            .filter(|(_, thread_id)| *thread_id == &command.thread_id)
            .map(|(turn_id, _)| turn_id.clone())
            .collect();
        for turn_id in removed_turns {
            self.raw_history.remove_turn(&turn_id);
            if let Some(started_turn) = self.stable_turn_starts.remove(&turn_id)
                && let Some(user_item_id) = started_turn.user_item_id()
            {
                self.item_ids.remove(user_item_id);
            }
            self.turn_threads.remove(&turn_id);
            self.turns.remove(&turn_id);
            self.completed_turn_ids.remove(&turn_id);
        }
        self.turn_order
            .retain(|turn_id| self.turns.contains_key(turn_id));
        let removed_items: Vec<String> = self
            .items
            .iter()
            .filter(|(_, item)| item.thread_id == command.thread_id)
            .map(|(item_id, _)| item_id.clone())
            .collect();
        for item_id in removed_items {
            self.items.remove(&item_id);
            self.item_ids.remove(&item_id);
        }
        self.item_order
            .retain(|item_id| self.items.contains_key(item_id));
        self.thread_goals.remove(&command.thread_id);
        self.thread_settings.remove(&command.thread_id);
        Ok(events)
    }

    fn fork_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadForkCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        require_uuid(&command.new_thread_id)?;
        require_text(&command.title)?;
        if self.contains_any_id(&command.new_thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let Some(source_thread) = self.threads.get(&command.thread_id).cloned() else {
            return Err(CoreError::InvalidArgument);
        };
        let source_record = self
            .thread_records
            .get(&command.thread_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        if source_record.workspace_id() != source_thread.workspace_id {
            return Err(CoreError::InvalidArgument);
        }
        if source_record.has_official_metadata() && command.timestamp.is_none() {
            return Err(CoreError::InvalidArgument);
        }

        let source_turn_ids: Vec<String> = self
            .turn_order
            .iter()
            .filter(|turn_id| {
                self.turns
                    .get(*turn_id)
                    .is_some_and(|turn| turn.thread_id == command.thread_id)
            })
            .cloned()
            .collect();
        let included_turn_ids = if let Some(last_turn_id) = command.last_turn_id.as_ref() {
            require_uuid(last_turn_id)?;
            let Some(index) = source_turn_ids
                .iter()
                .position(|turn_id| turn_id == last_turn_id)
            else {
                return Err(CoreError::InvalidArgument);
            };
            source_turn_ids[..=index].to_vec()
        } else {
            source_turn_ids
        };
        if included_turn_ids.iter().any(|turn_id| {
            self.turns
                .get(turn_id)
                .is_none_or(|turn| turn.status == TurnStatusWire::Running)
        }) {
            return Err(CoreError::InvalidArgument);
        }
        let included_turn_set: HashSet<&str> =
            included_turn_ids.iter().map(String::as_str).collect();
        let included_item_ids: Vec<String> = self
            .item_order
            .iter()
            .filter(|item_id| {
                self.items
                    .get(*item_id)
                    .is_some_and(|item| included_turn_set.contains(item.turn_id.as_str()))
            })
            .cloned()
            .collect();
        if command.turn_id_map.len() != included_turn_ids.len()
            || command.item_id_map.len() != included_item_ids.len()
            || !included_turn_ids
                .iter()
                .all(|id| command.turn_id_map.contains_key(id))
            || !included_item_ids
                .iter()
                .all(|id| command.item_id_map.contains_key(id))
        {
            return Err(CoreError::InvalidArgument);
        }

        let mut destination_ids = HashSet::new();
        destination_ids.insert(command.new_thread_id.clone());
        for id in command
            .turn_id_map
            .values()
            .chain(command.item_id_map.values())
        {
            require_uuid(id)?;
            if self.contains_any_id(id) || !destination_ids.insert(id.clone()) {
                return Err(CoreError::InvalidArgument);
            }
        }

        let forked_thread = ThreadWire {
            id: command.new_thread_id,
            workspace_id: source_record.workspace_id().to_owned(),
            title: command.title.trim().to_owned(),
        };
        let forked_goal = self
            .thread_goals
            .get(&command.thread_id)
            .cloned()
            .map(|mut goal| {
                goal.thread_id = forked_thread.id.clone();
                goal
            });
        let forked_settings = command
            .settings_override
            .or_else(|| self.thread_settings.get(&command.thread_id).cloned());
        let mut forked_turns = Vec::with_capacity(included_turn_ids.len());
        for source_id in &included_turn_ids {
            let source = self
                .turns
                .get(source_id)
                .ok_or(CoreError::InvalidArgument)?;
            forked_turns.push(TurnWire {
                id: command.turn_id_map[source_id].clone(),
                thread_id: forked_thread.id.clone(),
                status: source.status,
            });
        }
        let turn_map = &command.turn_id_map;
        let mut forked_items = Vec::with_capacity(included_item_ids.len());
        for source_id in &included_item_ids {
            let source = self
                .items
                .get(source_id)
                .ok_or(CoreError::InvalidArgument)?;
            forked_items.push(ThreadItemWire {
                id: command.item_id_map[source_id].clone(),
                thread_id: forked_thread.id.clone(),
                turn_id: turn_map[&source.turn_id].clone(),
                kind: source.kind,
                text: source.text.clone(),
            });
        }
        let mut forked_record = source_record.fork(
            forked_thread.id.clone(),
            forked_thread.title.clone(),
            forked_thread.workspace_id.clone(),
            command.timestamp,
            &forked_items,
        )?;
        forked_record.apply_fork_overrides(
            command.ephemeral,
            match command.thread_source {
                PatchField::Missing => None,
                PatchField::Null => Some(None),
                PatchField::Value(value) => Some(Some(value)),
            },
        )?;

        let mut events = Vec::with_capacity(2 + forked_turns.len() + forked_items.len());
        events.push(
            serde_json::to_vec(&ThreadUpsertedEvent {
                sequence,
                kind: "threadUpserted",
                thread: &forked_thread,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        );
        let mut next_sequence = sequence + 1;
        if let Some(goal) = forked_goal.as_ref() {
            events.push(
                serde_json::to_vec(&ThreadGoalUpdatedEvent {
                    sequence: next_sequence,
                    kind: "threadGoalUpdated",
                    thread_id: &forked_thread.id,
                    turn_id: None,
                    goal,
                })
                .map_err(|_| CoreError::InvalidJson)?,
            );
            next_sequence += 1;
        }
        if let Some(settings) = forked_settings.as_ref() {
            events.push(
                serde_json::to_vec(&serde_json::json!({
                    "sequence": next_sequence,
                    "kind": "threadSettingsUpdated",
                    "threadId": &forked_thread.id,
                    "threadSettings": settings,
                }))
                .map_err(|_| CoreError::InvalidJson)?,
            );
            next_sequence += 1;
        }
        for turn in &forked_turns {
            events.push(
                serde_json::to_vec(&TurnStartedEvent {
                    sequence: next_sequence,
                    kind: "turnStarted",
                    turn,
                })
                .map_err(|_| CoreError::InvalidJson)?,
            );
            next_sequence += 1;
            for item in forked_items.iter().filter(|item| item.turn_id == turn.id) {
                events.push(
                    serde_json::to_vec(&ItemAppendedEvent {
                        sequence: next_sequence,
                        kind: "itemAppended",
                        item,
                    })
                    .map_err(|_| CoreError::InvalidJson)?,
                );
                next_sequence += 1;
            }
        }

        self.thread_ids.insert(forked_thread.id.clone());
        self.thread_records
            .insert(forked_thread.id.clone(), forked_record);
        if let Some(settings) = forked_settings {
            self.thread_settings
                .insert(forked_thread.id.clone(), settings);
        }
        self.threads.insert(forked_thread.id.clone(), forked_thread);
        if let Some(goal) = forked_goal {
            self.thread_goals.insert(goal.thread_id.clone(), goal);
        }
        for turn in forked_turns {
            self.turn_threads
                .insert(turn.id.clone(), turn.thread_id.clone());
            if turn.status != TurnStatusWire::Running {
                self.completed_turn_ids.insert(turn.id.clone());
            }
            self.turn_order.push(turn.id.clone());
            self.turns.insert(turn.id.clone(), turn);
        }
        for item in forked_items {
            self.item_order.push(item.id.clone());
            self.item_ids.insert(item.id.clone());
            self.items.insert(item.id.clone(), item);
        }
        Ok(events)
    }

    fn rollback_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadRollbackCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        if command.num_turns == 0 || !self.thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let thread_turn_ids: Vec<String> = self
            .turn_order
            .iter()
            .filter(|turn_id| {
                self.turns
                    .get(*turn_id)
                    .is_some_and(|turn| turn.thread_id == command.thread_id)
            })
            .cloned()
            .collect();
        if command.num_turns > thread_turn_ids.len() {
            return Err(CoreError::InvalidArgument);
        }
        let removed_turn_ids =
            thread_turn_ids[thread_turn_ids.len() - command.num_turns..].to_vec();
        if removed_turn_ids.iter().any(|turn_id| {
            self.turns
                .get(turn_id)
                .is_none_or(|turn| turn.status == TurnStatusWire::Running)
        }) {
            return Err(CoreError::InvalidArgument);
        }
        let removed_turn_set: HashSet<&str> = removed_turn_ids.iter().map(String::as_str).collect();
        let removed_item_ids: Vec<String> = self
            .item_order
            .iter()
            .filter(|item_id| {
                self.items
                    .get(*item_id)
                    .is_some_and(|item| removed_turn_set.contains(item.turn_id.as_str()))
            })
            .cloned()
            .collect();
        let event = serde_json::to_vec(&serde_json::json!({
            "sequence": sequence,
            "kind": "threadRolledBack",
            "threadId": command.thread_id,
            "removedTurnIds": removed_turn_ids,
        }))
        .map_err(|_| CoreError::InvalidJson)?;

        for item_id in removed_item_ids {
            self.items.remove(&item_id);
            self.item_ids.remove(&item_id);
        }
        self.item_order
            .retain(|item_id| self.items.contains_key(item_id));
        for turn_id in &removed_turn_ids {
            self.raw_history.remove_turn(turn_id);
            self.stable_turn_starts.remove(turn_id);
            self.turn_threads.remove(turn_id);
            self.turns.remove(turn_id);
            self.completed_turn_ids.remove(turn_id);
        }
        self.turn_order
            .retain(|turn_id| !removed_turn_set.contains(turn_id.as_str()));
        Ok(vec![event])
    }

    pub(crate) fn thread_revert_response(&self, thread_id: &str) -> Result<Vec<u8>, CoreError> {
        let thread: serde_json::Value = serde_json::from_slice(&thread_directory::read(
            &self.thread_records,
            &self.turn_order,
            &self.turns,
            &self.item_order,
            &self.items,
            &serde_json::json!({"threadId": thread_id}),
        )?)
        .map_err(|_| CoreError::InvalidJson)?;
        let last_turn_id = self
            .turn_order
            .iter()
            .rev()
            .find(|turn_id| {
                self.turns
                    .get(*turn_id)
                    .is_some_and(|turn| turn.thread_id == thread_id)
            })
            .cloned();
        let last_item_id = self
            .item_order
            .iter()
            .rev()
            .find(|item_id| {
                self.items
                    .get(*item_id)
                    .is_some_and(|item| item.thread_id == thread_id)
            })
            .cloned();
        let cursor = |kind: &str, anchor_id: Option<String>| {
            anchor_id.map(|anchor_id| {
                base64::engine::general_purpose::STANDARD.encode(
                    serde_json::to_vec(&serde_json::json!({
                        "version": 1,
                        "kind": kind,
                        "threadID": thread_id,
                        "turnID": serde_json::Value::Null,
                        "anchorID": anchor_id,
                        "includeAnchor": true,
                    }))
                    .expect("cursor encoding is infallible"),
                )
            })
        };
        let thread = thread
            .get("thread")
            .cloned()
            .ok_or(CoreError::InvalidJson)?;
        serde_json::to_vec(&serde_json::json!({
            "thread": thread,
            "turnsBackwardsCursor": cursor("turn", last_turn_id),
            "itemsBackwardsCursor": cursor("item", last_item_id),
        }))
        .map_err(|_| CoreError::InvalidJson)
    }

    fn revert_thread(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: ThreadRevertCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        require_uuid(&command.before_turn_id)?;
        if !self.thread_ids.contains(&command.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        let thread_turn_ids: Vec<String> = self
            .turn_order
            .iter()
            .filter(|turn_id| {
                self.turns
                    .get(*turn_id)
                    .is_some_and(|turn| turn.thread_id == command.thread_id)
            })
            .cloned()
            .collect();
        let Some(before_index) = thread_turn_ids
            .iter()
            .position(|turn_id| turn_id == &command.before_turn_id)
        else {
            return Err(CoreError::InvalidArgument);
        };
        let removed_turn_ids = thread_turn_ids[before_index..].to_vec();
        if removed_turn_ids.iter().any(|turn_id| {
            self.turns
                .get(turn_id)
                .is_none_or(|turn| turn.status == TurnStatusWire::Running)
        }) {
            return Err(CoreError::InvalidArgument);
        }
        let removed_turn_set: HashSet<&str> = removed_turn_ids.iter().map(String::as_str).collect();
        let removed_item_ids: Vec<String> = self
            .item_order
            .iter()
            .filter(|item_id| {
                self.items
                    .get(*item_id)
                    .is_some_and(|item| removed_turn_set.contains(item.turn_id.as_str()))
            })
            .cloned()
            .collect();
        let event = serde_json::to_vec(&serde_json::json!({
            "sequence": sequence,
            "kind": "threadReverted",
            "threadId": command.thread_id,
            "beforeTurnId": command.before_turn_id,
            "removedTurnIds": removed_turn_ids,
        }))
        .map_err(|_| CoreError::InvalidJson)?;

        for item_id in removed_item_ids {
            self.items.remove(&item_id);
            self.item_ids.remove(&item_id);
        }
        self.item_order
            .retain(|item_id| self.items.contains_key(item_id));
        for turn_id in &removed_turn_ids {
            self.raw_history.remove_turn(turn_id);
            self.stable_turn_starts.remove(turn_id);
            self.turn_threads.remove(turn_id);
            self.turns.remove(turn_id);
            self.completed_turn_ids.remove(turn_id);
        }
        self.turn_order
            .retain(|turn_id| !removed_turn_set.contains(turn_id.as_str()));
        Ok(vec![event])
    }

    fn start_turn(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: TurnStartCommand = decode(input)?;
        let turn = command.turn;
        let item = command.user_item;
        require_uuid(&turn.id)?;
        require_uuid(&turn.thread_id)?;
        require_uuid(&item.id)?;
        require_uuid(&item.thread_id)?;
        require_uuid(&item.turn_id)?;
        require_text(&item.text)?;
        if turn.status != TurnStatusWire::Running
            || item.kind != ThreadItemKindWire::UserMessage
            || turn.thread_id != item.thread_id
            || turn.id != item.turn_id
            || !self.thread_ids.contains(&turn.thread_id)
            || self.contains_any_id(&turn.id)
            || self.contains_any_id(&item.id)
            || turn.id == item.id
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut record = self
            .thread_records
            .get(&turn.thread_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let updated_record = match command.timestamp {
            Some(timestamp) => {
                record.start_turn(timestamp, &item.text)?;
                Some(record)
            }
            None if record.has_official_metadata() => return Err(CoreError::InvalidArgument),
            None => None,
        };

        let turn_event = serde_json::to_vec(&TurnStartedEvent {
            sequence,
            kind: "turnStarted",
            turn: &turn,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        let item_event = serde_json::to_vec(&ItemAppendedEvent {
            sequence: sequence + 1,
            kind: "itemAppended",
            item: &item,
        })
        .map_err(|_| CoreError::InvalidJson)?;

        self.turn_threads
            .insert(turn.id.clone(), turn.thread_id.clone());
        self.turn_order.push(turn.id.clone());
        self.turns.insert(turn.id.clone(), turn);
        self.item_order.push(item.id.clone());
        self.item_ids.insert(item.id.clone());
        self.items.insert(item.id.clone(), item);
        if let Some(record) = updated_record {
            self.thread_records
                .insert(record.thread_id().to_owned(), record);
        }
        Ok(vec![turn_event, item_event])
    }

    fn start_stable_turn(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: StableTurnStartCommand = decode(input)?;
        require_uuid(&command.turn_id)?;
        require_uuid(&command.user_item_id)?;
        if command.kind != "turn.stable-start"
            || command.turn_id == command.user_item_id
            || self.contains_any_id(&command.turn_id)
            || self.contains_any_id(&command.user_item_id)
            || command
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .is_none_or(|thread_id| !thread_id.eq_ignore_ascii_case(&command.thread_id))
        {
            return Err(CoreError::InvalidArgument);
        }
        let (started_turn, _) = turn_start::prepare(
            &self.thread_ids,
            &command.params,
            command.turn_id.clone(),
            command.user_item_id.clone(),
        )?;
        if !started_turn
            .thread_id()
            .eq_ignore_ascii_case(&command.thread_id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut events = Vec::new();
        if let Some(notification) = thread_settings::apply_turn_patch(
            &self.thread_ids,
            &self.thread_records,
            &mut self.thread_settings,
            command.settings_patch.as_ref(),
        )? {
            events.push(notification);
        }
        let canonical_thread_id = started_turn.thread_id().to_owned();
        let persisted_params = started_turn.raw_params();
        self.thread_records
            .get_mut(&canonical_thread_id)
            .ok_or(CoreError::InvalidArgument)?
            .apply_turn_runtime(persisted_params)?;
        let event = serde_json::to_vec(&StableTurnStartedEvent {
            sequence: sequence + events.len() as u64,
            kind: "stableTurnStarted",
            thread_id: &canonical_thread_id,
            turn_id: &command.turn_id,
            user_item_id: &command.user_item_id,
            params: persisted_params,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        events.push(event);

        self.turn_threads
            .insert(command.turn_id.clone(), canonical_thread_id.clone());
        self.turn_order.push(command.turn_id.clone());
        self.turns.insert(
            command.turn_id.clone(),
            TurnWire {
                id: command.turn_id.clone(),
                thread_id: canonical_thread_id,
                status: TurnStatusWire::Running,
            },
        );
        if let Some(user_item_id) = started_turn.user_item_id() {
            self.item_ids.insert(user_item_id.to_owned());
        }
        self.stable_turn_starts
            .insert(command.turn_id, started_turn);
        Ok(events)
    }

    fn start_stable_compaction(
        &mut self,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: StableCompactStartCommand = decode(input)?;
        require_uuid(&command.thread_id)?;
        require_uuid(&command.turn_id)?;
        require_uuid(&command.item_id)?;
        if command.kind != "thread.compact-start"
            || !self.thread_ids.contains(&command.thread_id)
            || command.turn_id == command.item_id
            || self.contains_any_id(&command.turn_id)
            || self.contains_any_id(&command.item_id)
            || self.turns.values().any(|turn| {
                turn.thread_id == command.thread_id && turn.status == TurnStatusWire::Running
            })
        {
            return Err(CoreError::InvalidArgument);
        }
        let turn = TurnWire {
            id: command.turn_id.clone(),
            thread_id: command.thread_id.clone(),
            status: TurnStatusWire::Running,
        };
        let item = ThreadItemWire {
            id: command.item_id.clone(),
            thread_id: command.thread_id.clone(),
            turn_id: command.turn_id.clone(),
            kind: ThreadItemKindWire::ContextCompaction,
            text: String::new(),
        };
        let events = vec![
            serde_json::to_vec(&TurnStartedEvent {
                sequence,
                kind: "turnStarted",
                turn: &turn,
            })
            .map_err(|_| CoreError::InvalidJson)?,
            serde_json::to_vec(&ItemAppendedEvent {
                sequence: sequence + 1,
                kind: "itemAppended",
                item: &item,
            })
            .map_err(|_| CoreError::InvalidJson)?,
            serde_json::to_vec(&StableCompactStartedEvent {
                sequence: sequence + 2,
                kind: "stableCompactStarted",
                thread_id: &command.thread_id,
                turn_id: &command.turn_id,
                item_id: &command.item_id,
            })
            .map_err(|_| CoreError::InvalidJson)?,
        ];
        self.turn_threads
            .insert(command.turn_id.clone(), command.thread_id);
        self.turn_order.push(command.turn_id.clone());
        self.turns.insert(command.turn_id.clone(), turn);
        self.item_order.push(command.item_id.clone());
        self.item_ids.insert(command.item_id.clone());
        self.items.insert(command.item_id, item);
        Ok(events)
    }

    fn complete_turn(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: TurnCompleteCommand = decode(input)?;
        let turn_id = command.turn_id;
        let item = command.assistant_item;
        require_uuid(&turn_id)?;
        require_uuid(&item.id)?;
        require_uuid(&item.thread_id)?;
        require_uuid(&item.turn_id)?;
        require_text(&item.text)?;
        let Some(thread_id) = self.turn_threads.get(&turn_id).cloned() else {
            return Err(CoreError::InvalidArgument);
        };
        if item.kind != ThreadItemKindWire::AssistantMessage
            || item.turn_id != turn_id
            || item.thread_id != thread_id
            || self.completed_turn_ids.contains(&turn_id)
            || self.contains_any_id(&item.id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut record = self
            .thread_records
            .get(&thread_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let updated_record = match command.timestamp {
            Some(timestamp) => {
                record.finish_turn(timestamp, ThreadTerminalStatus::Completed)?;
                Some(record)
            }
            None if record.has_official_metadata() => return Err(CoreError::InvalidArgument),
            None => None,
        };

        let item_event = serde_json::to_vec(&ItemAppendedEvent {
            sequence,
            kind: "itemAppended",
            item: &item,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        let status_event = serde_json::to_vec(&TurnStatusChangedEvent {
            sequence: sequence + 1,
            kind: "turnStatusChanged",
            turn_id: &turn_id,
            status: TurnStatusWire::Completed,
        })
        .map_err(|_| CoreError::InvalidJson)?;

        self.item_order.push(item.id.clone());
        self.item_ids.insert(item.id.clone());
        self.items.insert(item.id.clone(), item);
        self.completed_turn_ids.insert(turn_id.clone());
        if let Some(turn) = self.turns.get_mut(&turn_id) {
            turn.status = TurnStatusWire::Completed;
        }
        if let Some(record) = updated_record {
            self.thread_records.insert(thread_id, record);
        }
        Ok(vec![item_event, status_event])
    }

    fn fail_turn(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: TurnFailCommand = decode(input)?;
        let turn_id = command.turn_id;
        let item = command.error_item;
        require_uuid(&turn_id)?;
        require_uuid(&item.id)?;
        require_uuid(&item.thread_id)?;
        require_uuid(&item.turn_id)?;
        require_text(&item.text)?;
        let Some(thread_id) = self.turn_threads.get(&turn_id).cloned() else {
            return Err(CoreError::InvalidArgument);
        };
        if item.kind != ThreadItemKindWire::Error
            || item.turn_id != turn_id
            || item.thread_id != thread_id
            || self.completed_turn_ids.contains(&turn_id)
            || self.contains_any_id(&item.id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let mut record = self
            .thread_records
            .get(&thread_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let updated_record = match command.timestamp {
            Some(timestamp) => {
                record.finish_turn(timestamp, ThreadTerminalStatus::Failed)?;
                Some(record)
            }
            None if record.has_official_metadata() => return Err(CoreError::InvalidArgument),
            None => None,
        };

        let item_event = serde_json::to_vec(&ItemAppendedEvent {
            sequence,
            kind: "itemAppended",
            item: &item,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        let status_event = serde_json::to_vec(&TurnStatusChangedEvent {
            sequence: sequence + 1,
            kind: "turnStatusChanged",
            turn_id: &turn_id,
            status: TurnStatusWire::Failed,
        })
        .map_err(|_| CoreError::InvalidJson)?;

        self.item_order.push(item.id.clone());
        self.item_ids.insert(item.id.clone());
        self.items.insert(item.id.clone(), item);
        self.completed_turn_ids.insert(turn_id.clone());
        if let Some(turn) = self.turns.get_mut(&turn_id) {
            turn.status = TurnStatusWire::Failed;
        }
        if let Some(record) = updated_record {
            self.thread_records.insert(thread_id, record);
        }
        Ok(vec![item_event, status_event])
    }

    fn cancel_turn(&mut self, input: &[u8], sequence: u64) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: TurnCancelCommand = decode(input)?;
        require_uuid(&command.turn_id)?;
        if !self.turn_threads.contains_key(&command.turn_id)
            || self.completed_turn_ids.contains(&command.turn_id)
        {
            return Err(CoreError::InvalidArgument);
        }
        let thread_id = self
            .turn_threads
            .get(&command.turn_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let mut record = self
            .thread_records
            .get(&thread_id)
            .cloned()
            .ok_or(CoreError::InvalidArgument)?;
        let updated_record = match command.timestamp {
            Some(timestamp) => {
                record.finish_turn(timestamp, ThreadTerminalStatus::Cancelled)?;
                Some(record)
            }
            None if record.has_official_metadata() => return Err(CoreError::InvalidArgument),
            None => None,
        };
        let event = serde_json::to_vec(&TurnStatusChangedEvent {
            sequence,
            kind: "turnStatusChanged",
            turn_id: &command.turn_id,
            status: TurnStatusWire::Cancelled,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        self.completed_turn_ids.insert(command.turn_id.clone());
        if let Some(turn) = self.turns.get_mut(&command.turn_id) {
            turn.status = TurnStatusWire::Cancelled;
        }
        if let Some(record) = updated_record {
            self.thread_records.insert(thread_id, record);
        }
        Ok(vec![event])
    }

    fn contains_any_id(&self, id: &str) -> bool {
        self.workspace_ids
            .iter()
            .any(|known| known.eq_ignore_ascii_case(id))
            || self
                .thread_ids
                .iter()
                .any(|known| known.eq_ignore_ascii_case(id))
            || self
                .turn_threads
                .keys()
                .any(|known| known.eq_ignore_ascii_case(id))
            || self
                .item_ids
                .iter()
                .any(|known| known.eq_ignore_ascii_case(id))
    }

    fn generate_unique_uuid_v7(&self) -> String {
        loop {
            let id = codex_protocol::ThreadId::new().to_string();
            if !self.contains_any_id(&id) {
                return id;
            }
        }
    }
}

fn decode<'a, T: Deserialize<'a>>(input: &'a [u8]) -> Result<T, CoreError> {
    serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)
}

fn encode_events<T: Serialize, const N: usize>(events: [T; N]) -> Result<Vec<Vec<u8>>, CoreError> {
    events
        .iter()
        .map(|event| serde_json::to_vec(event).map_err(|_| CoreError::InvalidJson))
        .collect()
}

fn require_text(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        Err(CoreError::InvalidArgument)
    } else {
        Ok(())
    }
}

fn require_uuid(value: &str) -> Result<(), CoreError> {
    let bytes = value.as_bytes();
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

fn normalize_approval_policy(value: serde_json::Value) -> Result<serde_json::Value, CoreError> {
    if matches!(value.as_str(), Some("untrusted" | "on-request" | "never")) {
        return Ok(value);
    }
    let granular = value
        .get("granular")
        .and_then(serde_json::Value::as_object)
        .ok_or(CoreError::InvalidArgument)?;
    let fields = [
        "sandbox_approval",
        "rules",
        "skill_approval",
        "request_permissions",
        "mcp_elicitations",
    ];
    if granular.len() != fields.len()
        || fields.iter().any(|field| {
            granular
                .get(*field)
                .and_then(serde_json::Value::as_bool)
                .is_none()
        })
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(value)
}

fn default_workspace_write_sandbox_policy() -> serde_json::Value {
    serde_json::json!({
        "type": "workspaceWrite",
        "writableRoots": [],
        "networkAccess": false,
        "excludeTmpdirEnvVar": false,
        "excludeSlashTmp": false,
    })
}

fn normalize_sandbox_policy(value: serde_json::Value) -> Result<serde_json::Value, CoreError> {
    let object = value.as_object().ok_or(CoreError::InvalidArgument)?;
    let policy_type = object
        .get("type")
        .and_then(serde_json::Value::as_str)
        .ok_or(CoreError::InvalidArgument)?;
    match policy_type {
        "dangerFullAccess" if object.len() == 1 => Ok(value),
        "readOnly" => {
            if object.len() != 2 {
                return Err(CoreError::InvalidArgument);
            }
            object
                .get("networkAccess")
                .and_then(serde_json::Value::as_bool)
                .ok_or(CoreError::InvalidArgument)?;
            Ok(value)
        }
        "externalSandbox" => {
            if object.len() != 2 {
                return Err(CoreError::InvalidArgument);
            }
            let network_access = object
                .get("networkAccess")
                .and_then(serde_json::Value::as_str)
                .ok_or(CoreError::InvalidArgument)?;
            if !matches!(network_access, "restricted" | "enabled") {
                return Err(CoreError::InvalidArgument);
            }
            Ok(value)
        }
        "workspaceWrite" => {
            if object.len() != 5 {
                return Err(CoreError::InvalidArgument);
            }
            let writable_roots = object
                .get("writableRoots")
                .and_then(serde_json::Value::as_array)
                .ok_or(CoreError::InvalidArgument)?;
            if writable_roots.iter().any(|root| {
                root.as_str()
                    .is_none_or(|path| !std::path::Path::new(path).is_absolute())
            }) {
                return Err(CoreError::InvalidArgument);
            }
            object
                .get("networkAccess")
                .and_then(serde_json::Value::as_bool)
                .ok_or(CoreError::InvalidArgument)?;
            object
                .get("excludeTmpdirEnvVar")
                .and_then(serde_json::Value::as_bool)
                .ok_or(CoreError::InvalidArgument)?;
            object
                .get("excludeSlashTmp")
                .and_then(serde_json::Value::as_bool)
                .ok_or(CoreError::InvalidArgument)?;
            Ok(value)
        }
        _ => Err(CoreError::InvalidArgument),
    }
}

#[cfg(test)]
mod tests {
    use super::{CoreError, normalize_sandbox_policy};

    #[test]
    fn sandbox_policy_requires_every_stable_variant_field() {
        let incomplete = [
            serde_json::json!({"type": "readOnly"}),
            serde_json::json!({"type": "externalSandbox"}),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["/workspace"],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false
            }),
        ];

        for policy in incomplete {
            assert_eq!(
                normalize_sandbox_policy(policy),
                Err(CoreError::InvalidArgument)
            );
        }
    }

    #[test]
    fn sandbox_policy_rejects_unknown_fields_and_non_absolute_roots() {
        let invalid = [
            serde_json::json!({"type": "dangerFullAccess", "networkAccess": false}),
            serde_json::json!({
                "type": "readOnly",
                "networkAccess": false,
                "unexpected": true
            }),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["relative/path"],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            }),
        ];

        for policy in invalid {
            assert_eq!(
                normalize_sandbox_policy(policy),
                Err(CoreError::InvalidArgument)
            );
        }
    }

    #[test]
    fn sandbox_policy_accepts_exact_stable_schema() {
        let policies = [
            serde_json::json!({"type": "dangerFullAccess"}),
            serde_json::json!({"type": "readOnly", "networkAccess": true}),
            serde_json::json!({
                "type": "externalSandbox",
                "networkAccess": "restricted"
            }),
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": ["/workspace", "/tmp/project"],
                "networkAccess": false,
                "excludeTmpdirEnvVar": true,
                "excludeSlashTmp": false
            }),
        ];

        for policy in policies {
            assert_eq!(normalize_sandbox_policy(policy.clone()), Ok(policy));
        }
    }
}
