use super::{
    ThreadItemKindWire, ThreadItemWire, ThreadMemoryModeWire, TurnStatusWire, TurnWire,
    require_uuid,
};
use crate::CoreError;
use crate::storage::{PINNED_THREAD_SECTION_ID, PINNED_THREAD_SECTION_NAME};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::Path;

const DEFAULT_LIMIT: usize = 25;
const MAX_LIMIT: usize = 100;
const DEFAULT_MODEL_PROVIDER: &str = "openai";
const CURSOR_PREFIX: &str = "ct1.";
const SEARCH_CURSOR_PREFIX: &str = "cs1.";
const MAX_CURSOR_HEX_BYTES: usize = 8 * 1024;

fn default_thread_mode() -> String {
    "default".to_owned()
}

/// Metadata captured when a thread is created.
///
/// This mirrors the stable app-server `Thread` metadata fields while keeping
/// runtime status and the user-facing name under `ThreadRecord` control.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ThreadCreateMetadata {
    session_id: String,
    #[serde(default)]
    forked_from_id: Option<String>,
    preview: String,
    ephemeral: bool,
    #[serde(default = "default_thread_mode")]
    mode: String,
    model_provider: String,
    #[serde(default = "default_thread_mode")]
    thread_start_kind: String,
    created_at: i64,
    updated_at: i64,
    #[serde(default)]
    recency_at: Option<i64>,
    #[serde(default)]
    path: Option<String>,
    cwd: String,
    cli_version: String,
    source: SessionSource,
    #[serde(default)]
    thread_source: Option<String>,
    #[serde(default)]
    parent_thread_id: Option<String>,
    #[serde(default)]
    agent_nickname: Option<String>,
    #[serde(default)]
    agent_role: Option<String>,
    #[serde(default)]
    git_info: Option<GitInfo>,
    #[serde(default)]
    runtime: ThreadRuntimeMetadata,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ThreadRuntimeMetadata {
    #[serde(default)]
    pub(super) runtime_workspace_roots: Option<Vec<String>>,
    #[serde(default)]
    pub(super) allow_provider_model_fallback: bool,
    #[serde(default)]
    pub(super) config: serde_json::Map<String, Value>,
    #[serde(default)]
    pub(super) service_name: Option<String>,
    #[serde(default)]
    pub(super) base_instructions: Option<String>,
    #[serde(default)]
    pub(super) developer_instructions: Option<String>,
    #[serde(default)]
    pub(super) history_mode: Option<String>,
    #[serde(default)]
    pub(super) environments: Option<Vec<Value>>,
    #[serde(default)]
    pub(super) dynamic_tools: Option<Vec<Value>>,
    #[serde(default)]
    pub(super) selected_capability_roots: Option<Vec<Value>>,
    #[serde(default)]
    pub(super) mock_experimental_field: Option<String>,
    #[serde(default)]
    pub(super) multi_agent_mode: Option<Value>,
    #[serde(default)]
    pub(super) experimental_raw_events: bool,
}

#[derive(Clone)]
pub(super) struct ThreadRecord {
    workspace_id: String,
    title: String,
    thread: Thread,
    memory_mode: ThreadMemoryModeWire,
    runtime: ThreadRuntimeMetadata,
    provenance: ThreadRecordProvenance,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ThreadRecordProvenance {
    OfficialMetadata,
    LegacyMissingMetadata,
}

impl ThreadRecord {
    pub(super) fn from_metadata(
        id: String,
        title: String,
        workspace_id: String,
        metadata: Option<ThreadCreateMetadata>,
    ) -> Result<Self, CoreError> {
        if id.trim().is_empty() || title.trim().is_empty() || workspace_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument);
        }

        match metadata {
            Some(metadata) => {
                metadata.validate()?;
                Ok(Self {
                    workspace_id,
                    title: title.clone(),
                    thread: Thread {
                        id,
                        session_id: metadata.session_id,
                        forked_from_id: metadata.forked_from_id,
                        parent_thread_id: metadata.parent_thread_id,
                        preview: metadata.preview,
                        ephemeral: metadata.ephemeral,
                        mode: metadata.mode,
                        is_pinned: false,
                        section: None,
                        model_provider: metadata.model_provider,
                        thread_start_kind: metadata.thread_start_kind,
                        created_at: metadata.created_at,
                        updated_at: metadata.updated_at,
                        recency_at: metadata.recency_at,
                        status: ThreadStatus::Idle,
                        path: metadata.path,
                        cwd: metadata.cwd,
                        cli_version: metadata.cli_version,
                        source: metadata.source,
                        thread_source: metadata.thread_source,
                        agent_nickname: metadata.agent_nickname,
                        agent_role: metadata.agent_role,
                        git_info: metadata.git_info,
                        name: Some(title),
                        turns: Vec::new(),
                    },
                    memory_mode: ThreadMemoryModeWire::Enabled,
                    runtime: metadata.runtime,
                    provenance: ThreadRecordProvenance::OfficialMetadata,
                })
            }
            None => Ok(Self::legacy(id, title, workspace_id)),
        }
    }

    fn legacy(id: String, title: String, workspace_id: String) -> Self {
        Self {
            workspace_id,
            title: title.clone(),
            thread: Thread {
                session_id: id.clone(),
                id,
                forked_from_id: None,
                parent_thread_id: None,
                preview: title.clone(),
                ephemeral: false,
                mode: default_thread_mode(),
                is_pinned: false,
                section: None,
                model_provider: String::new(),
                thread_start_kind: default_thread_mode(),
                created_at: 0,
                updated_at: 0,
                recency_at: None,
                status: ThreadStatus::Idle,
                path: None,
                cwd: String::new(),
                cli_version: String::new(),
                source: SessionSource::Unknown,
                thread_source: None,
                agent_nickname: None,
                agent_role: None,
                git_info: None,
                name: Some(title),
                turns: Vec::new(),
            },
            memory_mode: ThreadMemoryModeWire::Enabled,
            runtime: ThreadRuntimeMetadata::default(),
            provenance: ThreadRecordProvenance::LegacyMissingMetadata,
        }
    }

    pub(super) fn set_name(&mut self, name: String) -> Result<(), CoreError> {
        let name = name.trim().to_owned();
        if name.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        self.title = name.clone();
        self.thread.name = Some(name);
        Ok(())
    }

    pub(super) fn title(&self) -> &str {
        &self.title
    }

    pub(super) fn clear_name(&mut self) {
        self.thread.name = None;
    }

    pub(super) fn apply_fork_overrides(
        &mut self,
        ephemeral: Option<bool>,
        thread_source: Option<Option<String>>,
    ) -> Result<(), CoreError> {
        if !self.has_official_metadata() {
            return Ok(());
        }
        if let Some(ephemeral) = ephemeral {
            self.thread.ephemeral = ephemeral;
        }
        if let Some(thread_source) = thread_source {
            if thread_source
                .as_ref()
                .is_some_and(|source| source.trim().is_empty())
            {
                return Err(CoreError::InvalidArgument);
            }
            self.thread.thread_source = thread_source;
        }
        Ok(())
    }

    pub(super) fn fork(
        &self,
        id: String,
        title: String,
        workspace_id: String,
        timestamp: Option<i64>,
        included_items: &[ThreadItemWire],
    ) -> Result<Self, CoreError> {
        let title = title.trim().to_owned();
        if id.trim().is_empty() || title.is_empty() || workspace_id.trim().is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        if timestamp.is_some_and(|timestamp| timestamp < 0) {
            return Err(CoreError::InvalidArgument);
        }
        let Some(timestamp) = timestamp.filter(|_| self.has_official_metadata()) else {
            let mut legacy = Self::legacy(id, title, workspace_id);
            legacy.thread.forked_from_id = Some(self.thread.id.clone());
            return Ok(legacy);
        };

        let mut thread = self.thread.clone();
        thread.id = id;
        thread.session_id = thread.id.clone();
        thread.forked_from_id = Some(self.thread.id.clone());
        thread.parent_thread_id = None;
        thread.preview = included_items
            .iter()
            .find(|item| item.kind == ThreadItemKindWire::UserMessage)
            .map(|item| item.text.trim().to_owned())
            .unwrap_or_default();
        thread.created_at = timestamp;
        thread.updated_at = timestamp;
        thread.recency_at = Some(timestamp);
        thread.status = ThreadStatus::Idle;
        thread.path = None;
        thread.name = Some(title.clone());
        thread.turns.clear();
        Ok(Self {
            workspace_id,
            title,
            thread,
            memory_mode: self.memory_mode,
            runtime: self.runtime.clone(),
            provenance: ThreadRecordProvenance::OfficialMetadata,
        })
    }

    pub(super) fn set_memory_mode(&mut self, mode: ThreadMemoryModeWire) {
        self.memory_mode = mode;
    }

    #[cfg(test)]
    pub(super) fn memory_mode(&self) -> ThreadMemoryModeWire {
        self.memory_mode
    }

    pub(super) fn has_official_metadata(&self) -> bool {
        self.provenance == ThreadRecordProvenance::OfficialMetadata
    }

    pub(super) fn is_ephemeral(&self) -> bool {
        self.thread.ephemeral
    }

    pub(super) fn cwd(&self) -> &str {
        &self.thread.cwd
    }

    pub(super) fn path(&self) -> Option<&str> {
        self.thread.path.as_deref()
    }

    pub(super) fn model_provider(&self) -> &str {
        &self.thread.model_provider
    }

    pub(super) fn runtime(&self) -> &ThreadRuntimeMetadata {
        &self.runtime
    }

    pub(super) fn apply_turn_runtime(&mut self, params: &Value) -> Result<(), CoreError> {
        let params = params.as_object().ok_or(CoreError::InvalidArgument)?;
        if let Some(roots) = params.get("runtimeWorkspaceRoots") {
            self.runtime.runtime_workspace_roots = Some(
                serde_json::from_value(roots.clone()).map_err(|_| CoreError::InvalidArgument)?,
            );
        }
        if let Some(environments) = params.get("environments") {
            self.runtime.environments = Some(
                serde_json::from_value(environments.clone())
                    .map_err(|_| CoreError::InvalidArgument)?,
            );
        }
        if let Some(dynamic_tools) = params.get("dynamicTools") {
            self.runtime.dynamic_tools = Some(
                serde_json::from_value(dynamic_tools.clone())
                    .map_err(|_| CoreError::InvalidArgument)?,
            );
        }
        if let Some(selected_capability_roots) = params.get("selectedCapabilityRoots") {
            self.runtime.selected_capability_roots = Some(
                serde_json::from_value(selected_capability_roots.clone())
                    .map_err(|_| CoreError::InvalidArgument)?,
            );
        }
        Ok(())
    }

    pub(super) fn start_turn(&mut self, timestamp: i64, preview: &str) -> Result<(), CoreError> {
        if timestamp < 0 {
            return Err(CoreError::InvalidArgument);
        }
        if !self.has_official_metadata() {
            return Ok(());
        }
        let preview = preview.trim();
        if preview.is_empty() || timestamp < self.thread.updated_at {
            return Err(CoreError::InvalidArgument);
        }
        if self.thread.preview.trim().is_empty() {
            self.thread.preview = preview.to_owned();
        }
        self.thread.status = ThreadStatus::Active {
            active_flags: Vec::new(),
        };
        self.thread.updated_at = timestamp;
        self.thread.recency_at = Some(timestamp);
        Ok(())
    }

    pub(super) fn finish_turn(
        &mut self,
        timestamp: i64,
        terminal_status: ThreadTerminalStatus,
    ) -> Result<(), CoreError> {
        if timestamp < 0 {
            return Err(CoreError::InvalidArgument);
        }
        if !self.has_official_metadata() {
            return Ok(());
        }
        if timestamp < self.thread.updated_at {
            return Err(CoreError::InvalidArgument);
        }
        self.thread.status = match terminal_status {
            ThreadTerminalStatus::Completed | ThreadTerminalStatus::Cancelled => ThreadStatus::Idle,
            ThreadTerminalStatus::Failed => ThreadStatus::SystemError,
        };
        self.thread.updated_at = timestamp;
        self.thread.recency_at = Some(timestamp);
        Ok(())
    }

    pub(super) fn workspace_id(&self) -> &str {
        &self.workspace_id
    }

    pub(super) fn thread_id(&self) -> &str {
        &self.thread.id
    }

    fn timestamp(&self, sort_key: ThreadSortKey) -> i64 {
        match sort_key {
            ThreadSortKey::CreatedAt => self.thread.created_at,
            ThreadSortKey::UpdatedAt => self.thread.updated_at,
            ThreadSortKey::RecencyAt => self.thread.recency_at.unwrap_or(self.thread.updated_at),
        }
    }

    fn matches_search_term(&self, search_term: &str) -> bool {
        self.thread
            .name
            .as_deref()
            .is_some_and(|name| name.contains(search_term))
            || self.title.contains(search_term)
            || self.thread.preview.contains(search_term)
    }
}

impl ThreadCreateMetadata {
    fn validate(&self) -> Result<(), CoreError> {
        if self.session_id.trim().is_empty()
            || self.model_provider.trim().is_empty()
            || self.mode.trim().is_empty()
            || self.thread_start_kind.trim().is_empty()
            || self.cwd.trim().is_empty()
            || !Path::new(&self.cwd).is_absolute()
            || self.cli_version.trim().is_empty()
            || self.created_at < 0
            || self.updated_at < self.created_at
            || self
                .recency_at
                .is_some_and(|recency_at| recency_at < self.created_at)
            || self
                .path
                .as_ref()
                .is_some_and(|path| !Path::new(path).is_absolute())
            || [
                self.forked_from_id.as_deref(),
                self.thread_source.as_deref(),
                self.parent_thread_id.as_deref(),
                self.agent_nickname.as_deref(),
                self.agent_role.as_deref(),
                self.git_info
                    .as_ref()
                    .and_then(|git_info| git_info.sha.as_deref()),
                self.git_info
                    .as_ref()
                    .and_then(|git_info| git_info.branch.as_deref()),
                self.git_info
                    .as_ref()
                    .and_then(|git_info| git_info.origin_url.as_deref()),
            ]
            .into_iter()
            .flatten()
            .any(|value| value.trim().is_empty())
            || matches!(&self.source, SessionSource::Custom(name) if name.trim().is_empty())
        {
            return Err(CoreError::InvalidArgument);
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
pub(super) enum ThreadTerminalStatus {
    Completed,
    Failed,
    Cancelled,
}

/// Implements stable `thread/list` response semantics over the in-memory index.
pub(super) fn list(
    records: &HashMap<String, ThreadRecord>,
    archived_thread_ids: &HashSet<String>,
    params: &Value,
) -> Result<Vec<u8>, CoreError> {
    let query = EffectiveListQuery::parse(params)?;
    let fingerprint = query.filters.fingerprint()?;
    let cursor = query
        .cursor
        .as_deref()
        .map(|cursor| decode_cursor(cursor, &query, &fingerprint))
        .transpose()?;

    let mut matches = records
        .values()
        .filter(|record| record.has_official_metadata())
        .filter(|record| {
            query.filters.matches(
                record,
                archived_thread_ids.contains(&record.thread.id),
                records,
            )
        })
        .filter(|record| {
            cursor.as_ref().is_none_or(|cursor| {
                is_after_cursor(record, cursor, query.sort_key, query.sort_direction)
            })
        })
        .collect::<Vec<_>>();

    matches
        .sort_by(|left, right| compare_records(left, right, query.sort_key, query.sort_direction));

    let has_more = matches.len() > query.limit;
    matches.truncate(query.limit);
    let data = matches
        .iter()
        .map(|record| record.thread.clone())
        .collect::<Vec<_>>();

    let next_cursor = if has_more {
        matches
            .last()
            .map(|record| encode_cursor(record, query.sort_key, query.sort_direction, &fingerprint))
            .transpose()?
    } else {
        None
    };
    let backwards_cursor = matches
        .first()
        .map(|record| {
            encode_cursor(
                record,
                query.sort_key,
                query.sort_direction.opposite(),
                &fingerprint,
            )
        })
        .transpose()?;

    serde_json::to_vec(&ThreadListResponse {
        data,
        next_cursor,
        backwards_cursor,
    })
    .map_err(|_| CoreError::InvalidJson)
}

/// Implements stable `thread/read`, projecting persisted history only on demand.
pub(super) fn read(
    records: &HashMap<String, ThreadRecord>,
    turn_order: &[String],
    turns: &HashMap<String, TurnWire>,
    item_order: &[String],
    items: &HashMap<String, ThreadItemWire>,
    params: &Value,
) -> Result<Vec<u8>, CoreError> {
    let params: ThreadReadParams =
        serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
    if params.thread_id.trim().is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    let record = records
        .get(&params.thread_id)
        .filter(|record| record.has_official_metadata())
        .ok_or(CoreError::InvalidArgument)?;
    let thread = project_thread(
        record,
        turn_order,
        turns,
        item_order,
        items,
        params.include_turns,
    );
    serde_json::to_vec(&ThreadReadResponse { thread }).map_err(|_| CoreError::InvalidJson)
}

pub(super) fn project_thread(
    record: &ThreadRecord,
    turn_order: &[String],
    turns: &HashMap<String, TurnWire>,
    item_order: &[String],
    items: &HashMap<String, ThreadItemWire>,
    include_turns: bool,
) -> Thread {
    let mut thread = record.thread.clone();
    if include_turns {
        thread.turns = project_turns(record.thread_id(), turn_order, turns, item_order, items);
    }
    thread
}

fn project_turns(
    thread_id: &str,
    turn_order: &[String],
    turns: &HashMap<String, TurnWire>,
    item_order: &[String],
    items: &HashMap<String, ThreadItemWire>,
) -> Vec<ThreadTurn> {
    turn_order
        .iter()
        .filter_map(|turn_id| turns.get(turn_id))
        .filter(|turn| turn.thread_id == thread_id)
        .map(|turn| {
            let persisted_items = item_order
                .iter()
                .filter_map(|item_id| items.get(item_id))
                .filter(|item| item.thread_id == thread_id && item.turn_id == turn.id)
                .collect::<Vec<_>>();
            // A legacy error item has enough information for Turn.error, but
            // not for any stable v2 ThreadItem variant.
            let error = (turn.status == TurnStatusWire::Failed)
                .then(|| {
                    persisted_items
                        .iter()
                        .find(|item| item.kind == ThreadItemKindWire::Error)
                        .map(|item| ThreadTurnError {
                            message: item.text.clone(),
                            codex_error_info: None,
                            additional_details: None,
                        })
                })
                .flatten();
            // The legacy session index persists only a coarse `kind + text`
            // projection. Even when a user or assistant message can be shown,
            // optional fields and non-visible response items were not retained,
            // so a non-empty legacy turn must never claim a stable-v2 full view.
            let has_coarse_items = !persisted_items.is_empty();
            let items = persisted_items
                .into_iter()
                .filter_map(ThreadItem::from_wire)
                .collect();

            ThreadTurn {
                id: turn.id.clone(),
                items,
                items_view: if has_coarse_items {
                    ThreadTurnItemsView::Summary
                } else {
                    ThreadTurnItemsView::Full
                },
                status: turn.status.into(),
                error,
                // The legacy TurnWire has no timing fields; null is the exact
                // stable v2 representation for unknown timestamps/duration.
                started_at: None,
                completed_at: None,
                duration_ms: None,
            }
        })
        .collect()
}

/// Applies the stable `thread/metadata/update` tri-state Git patch.
pub(super) fn metadata_update(
    records: &mut HashMap<String, ThreadRecord>,
    params: &Value,
) -> Result<Vec<u8>, CoreError> {
    let params = params.as_object().ok_or(CoreError::InvalidArgument)?;
    let thread_id = params
        .get("threadId")
        .and_then(Value::as_str)
        .filter(|thread_id| !thread_id.trim().is_empty())
        .ok_or(CoreError::InvalidArgument)?;
    let git_patch = match params.get("gitInfo") {
        None => None,
        Some(Value::Null) => None,
        Some(Value::Object(git_info)) => {
            let sha = GitInfoFieldPatch::parse(git_info, "sha")?;
            let branch = GitInfoFieldPatch::parse(git_info, "branch")?;
            let origin_url = GitInfoFieldPatch::parse(git_info, "originUrl")?;
            if sha.is_unspecified() && branch.is_unspecified() && origin_url.is_unspecified() {
                return Err(CoreError::InvalidArgument);
            }
            Some(Some((sha, branch, origin_url)))
        }
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    let is_pinned = match params.get("isPinned") {
        None => None,
        Some(Value::Null) => Some(false),
        Some(Value::Bool(value)) => Some(*value),
        Some(_) => return Err(CoreError::InvalidArgument),
    };
    let section_id = parse_thread_section_id(params.get("sectionId"))?;
    if let Some(Some(section_id)) = section_id.as_ref()
        && section_id != PINNED_THREAD_SECTION_ID
    {
        return Err(CoreError::InvalidArgument);
    }
    if let (Some(section_id), Some(is_pinned)) = (section_id.as_ref(), is_pinned)
        && section_id.is_some() != is_pinned
    {
        return Err(CoreError::InvalidArgument);
    }
    if git_patch.is_none() && is_pinned.is_none() && section_id.is_none() {
        return Err(CoreError::InvalidArgument);
    }

    let record = records
        .get_mut(thread_id)
        .ok_or(CoreError::InvalidArgument)?;
    if let Some(git_patch) = git_patch {
        if let Some((sha, branch, origin_url)) = git_patch {
            let mut updated = record.thread.git_info.clone().unwrap_or_default();
            sha.apply(&mut updated.sha);
            branch.apply(&mut updated.branch);
            origin_url.apply(&mut updated.origin_url);
            record.thread.git_info =
                (updated.sha.is_some() || updated.branch.is_some() || updated.origin_url.is_some())
                    .then_some(updated);
        } else {
            record.thread.git_info = None;
        }
    }
    let section_is_pinned = section_id
        .as_ref()
        .map(|section_id| section_id.is_some())
        .or(is_pinned);
    if let Some(is_pinned) = section_is_pinned {
        record.thread.is_pinned = is_pinned;
        record.thread.section = is_pinned.then(ThreadSection::pinned);
    }

    serde_json::to_vec(&ThreadMetadataUpdateResponse {
        thread: record.thread.clone(),
    })
    .map_err(|_| CoreError::InvalidJson)
}

fn parse_thread_section_id(value: Option<&Value>) -> Result<Option<Option<String>>, CoreError> {
    match value {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(Value::String(section_id)) if !section_id.trim().is_empty() => {
            Ok(Some(Some(section_id.to_owned())))
        }
        Some(_) => Err(CoreError::InvalidArgument),
    }
}

/// Searches only the caller-projected visible user/assistant conversation text.
pub(super) fn search(
    records: &HashMap<String, ThreadRecord>,
    archived_thread_ids: &HashSet<String>,
    visible_content: &HashMap<String, Vec<String>>,
    params: &Value,
) -> Result<Vec<u8>, CoreError> {
    let query = EffectiveSearchQuery::parse(params)?;
    let fingerprint = query.filters.fingerprint()?;
    let cursor = query
        .cursor
        .as_deref()
        .map(|cursor| decode_search_cursor(cursor, &query, &fingerprint))
        .transpose()?;

    let mut matches = records
        .values()
        .filter(|record| record.has_official_metadata())
        .filter(|record| {
            query
                .filters
                .matches(record, archived_thread_ids.contains(&record.thread.id))
        })
        .filter(|record| {
            cursor.as_ref().is_none_or(|cursor| {
                is_after_search_cursor(record, cursor, query.sort_key, query.sort_direction)
            })
        })
        .filter_map(|record| {
            let snippet = visible_content
                .get(&record.thread.id)?
                .iter()
                .find(|text| {
                    text.to_lowercase()
                        .contains(&query.filters.normalized_search_term)
                })?;
            Some((record, snippet.clone()))
        })
        .collect::<Vec<_>>();

    matches.sort_by(|(left, _), (right, _)| {
        compare_records(left, right, query.sort_key, query.sort_direction)
    });

    let has_more = matches.len() > query.limit;
    matches.truncate(query.limit);
    let data = matches
        .iter()
        .map(|(record, snippet)| ThreadSearchResult {
            thread: record.thread.clone(),
            snippet: snippet.clone(),
        })
        .collect::<Vec<_>>();

    let next_cursor = if has_more {
        matches
            .last()
            .map(|(record, _)| {
                encode_search_cursor(record, query.sort_key, query.sort_direction, &fingerprint)
            })
            .transpose()?
    } else {
        None
    };
    let backwards_cursor = matches
        .first()
        .map(|(record, _)| {
            encode_search_cursor(
                record,
                query.sort_key,
                query.sort_direction.opposite(),
                &fingerprint,
            )
        })
        .transpose()?;

    serde_json::to_vec(&ThreadSearchResponse {
        data,
        next_cursor,
        backwards_cursor,
    })
    .map_err(|_| CoreError::InvalidJson)
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ThreadSection {
    id: String,
    name: String,
}

impl ThreadSection {
    fn pinned() -> Self {
        Self {
            id: PINNED_THREAD_SECTION_ID.to_owned(),
            name: PINNED_THREAD_SECTION_NAME.to_owned(),
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Thread {
    id: String,
    session_id: String,
    forked_from_id: Option<String>,
    parent_thread_id: Option<String>,
    preview: String,
    ephemeral: bool,
    mode: String,
    is_pinned: bool,
    section: Option<ThreadSection>,
    model_provider: String,
    thread_start_kind: String,
    created_at: i64,
    updated_at: i64,
    recency_at: Option<i64>,
    status: ThreadStatus,
    path: Option<String>,
    cwd: String,
    cli_version: String,
    source: SessionSource,
    thread_source: Option<String>,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    git_info: Option<GitInfo>,
    name: Option<String>,
    turns: Vec<ThreadTurn>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadTurn {
    id: String,
    items: Vec<ThreadItem>,
    items_view: ThreadTurnItemsView,
    status: ThreadTurnStatus,
    error: Option<ThreadTurnError>,
    started_at: Option<i64>,
    completed_at: Option<i64>,
    duration_ms: Option<i64>,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum ThreadTurnItemsView {
    Summary,
    Full,
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
enum ThreadTurnStatus {
    Completed,
    Interrupted,
    Failed,
    InProgress,
}

impl From<TurnStatusWire> for ThreadTurnStatus {
    fn from(status: TurnStatusWire) -> Self {
        match status {
            TurnStatusWire::Running => Self::InProgress,
            TurnStatusWire::Completed => Self::Completed,
            TurnStatusWire::Failed => Self::Failed,
            TurnStatusWire::Cancelled => Self::Interrupted,
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadTurnError {
    message: String,
    codex_error_info: Option<Value>,
    additional_details: Option<String>,
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum ThreadItem {
    UserMessage {
        id: String,
        #[serde(rename = "clientId")]
        client_id: Option<String>,
        content: Vec<ThreadUserInput>,
    },
    AgentMessage {
        id: String,
        text: String,
        phase: Option<Value>,
        #[serde(rename = "memoryCitation")]
        memory_citation: Option<Value>,
    },
    ContextCompaction {
        id: String,
    },
}

impl ThreadItem {
    fn from_wire(item: &ThreadItemWire) -> Option<Self> {
        match item.kind {
            ThreadItemKindWire::UserMessage => Some(Self::UserMessage {
                id: item.id.clone(),
                client_id: None,
                content: vec![ThreadUserInput::Text {
                    text: item.text.clone(),
                    text_elements: Vec::new(),
                }],
            }),
            ThreadItemKindWire::AssistantMessage => Some(Self::AgentMessage {
                id: item.id.clone(),
                text: item.text.clone(),
                phase: None,
                memory_citation: None,
            }),
            ThreadItemKindWire::ContextCompaction => Some(Self::ContextCompaction {
                id: item.id.clone(),
            }),
            // The legacy session index stores only `id + coarse kind + text`
            // for these items. Stable v2 requires structured payloads. In
            // particular, legacy reasoning text does not say whether it was a
            // summary or content block, so omit it rather than guess.
            ThreadItemKindWire::Reasoning
            | ThreadItemKindWire::ToolCall
            | ThreadItemKindWire::ToolResult
            | ThreadItemKindWire::Approval
            | ThreadItemKindWire::FileChange
            | ThreadItemKindWire::Terminal
            | ThreadItemKindWire::Error => None,
        }
    }
}

#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum ThreadUserInput {
    Text {
        text: String,
        #[serde(rename = "text_elements")]
        text_elements: Vec<Value>,
    },
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum SessionSource {
    Cli,
    #[serde(rename = "vscode")]
    VsCode,
    Exec,
    AppServer,
    Custom(String),
    SubAgent(Value),
    Unknown,
}

impl SessionSource {
    fn is_interactive(&self) -> bool {
        match self {
            Self::Cli | Self::VsCode => true,
            Self::Custom(source) => matches!(source.as_str(), "atlas" | "chatgpt"),
            Self::Exec | Self::AppServer | Self::SubAgent(_) | Self::Unknown => false,
        }
    }

    fn matches_kind(&self, kind: ThreadSourceKind) -> bool {
        match kind {
            ThreadSourceKind::Cli => matches!(self, Self::Cli),
            ThreadSourceKind::VsCode => matches!(self, Self::VsCode),
            ThreadSourceKind::Exec => matches!(self, Self::Exec),
            ThreadSourceKind::AppServer => matches!(self, Self::AppServer),
            ThreadSourceKind::SubAgent => matches!(self, Self::SubAgent(_)),
            ThreadSourceKind::SubAgentReview => {
                matches!(self, Self::SubAgent(Value::String(value)) if value == "review")
            }
            ThreadSourceKind::SubAgentCompact => {
                matches!(self, Self::SubAgent(Value::String(value)) if value == "compact")
            }
            ThreadSourceKind::SubAgentThreadSpawn => matches!(
                self,
                Self::SubAgent(Value::Object(value)) if value.contains_key("thread_spawn")
            ),
            ThreadSourceKind::SubAgentOther => matches!(
                self,
                Self::SubAgent(Value::Object(value)) if value.contains_key("other")
            ),
            ThreadSourceKind::Unknown => matches!(self, Self::Unknown),
        }
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GitInfo {
    #[serde(default)]
    sha: Option<String>,
    #[serde(default)]
    branch: Option<String>,
    #[serde(default)]
    origin_url: Option<String>,
}

#[allow(dead_code)]
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase", tag = "type")]
enum ThreadStatus {
    NotLoaded,
    Idle,
    SystemError,
    Active {
        #[serde(rename = "activeFlags")]
        active_flags: Vec<ThreadActiveFlag>,
    },
}

#[allow(dead_code)]
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
enum ThreadActiveFlag {
    WaitingOnApproval,
    WaitingOnUserInput,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadListResponse {
    data: Vec<Thread>,
    next_cursor: Option<String>,
    backwards_cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadReadParams {
    thread_id: String,
    #[serde(default)]
    include_turns: bool,
}

#[derive(Serialize)]
struct ThreadReadResponse {
    thread: Thread,
}

#[derive(Serialize)]
struct ThreadMetadataUpdateResponse {
    thread: Thread,
}

enum GitInfoFieldPatch {
    Unspecified,
    Clear,
    Replace(String),
}

impl GitInfoFieldPatch {
    fn parse(object: &serde_json::Map<String, Value>, field: &str) -> Result<Self, CoreError> {
        match object.get(field) {
            None => Ok(Self::Unspecified),
            Some(Value::Null) => Ok(Self::Clear),
            Some(Value::String(value)) => {
                let value = value.trim();
                if value.is_empty() {
                    Err(CoreError::InvalidArgument)
                } else {
                    Ok(Self::Replace(value.to_owned()))
                }
            }
            Some(_) => Err(CoreError::InvalidArgument),
        }
    }

    fn is_unspecified(&self) -> bool {
        matches!(self, Self::Unspecified)
    }

    fn apply(self, value: &mut Option<String>) {
        match self {
            Self::Unspecified => {}
            Self::Clear => *value = None,
            Self::Replace(replacement) => *value = Some(replacement),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSearchResult {
    thread: Thread,
    snippet: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSearchResponse {
    data: Vec<ThreadSearchResult>,
    next_cursor: Option<String>,
    backwards_cursor: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadListParams {
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    sort_key: Option<ThreadSortKey>,
    #[serde(default)]
    sort_direction: Option<SortDirection>,
    #[serde(default)]
    model_providers: Option<Vec<String>>,
    #[serde(default)]
    source_kinds: Option<Vec<ThreadSourceKind>>,
    #[serde(default)]
    archived: Option<bool>,
    #[serde(default)]
    is_pinned: Option<bool>,
    #[serde(default)]
    cwd: Option<ThreadListCwdFilter>,
    #[serde(default)]
    use_state_db_only: bool,
    #[serde(default)]
    search_term: Option<String>,
    #[serde(default)]
    parent_thread_id: Option<String>,
    #[serde(default)]
    ancestor_thread_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadSearchParams {
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<u32>,
    #[serde(default)]
    sort_key: Option<ThreadSortKey>,
    #[serde(default)]
    sort_direction: Option<SortDirection>,
    #[serde(default)]
    source_kinds: Option<Vec<ThreadSourceKind>>,
    #[serde(default)]
    archived: Option<bool>,
    search_term: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ThreadListCwdFilter {
    One(String),
    Many(Vec<String>),
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase")]
enum ThreadSourceKind {
    Cli,
    #[serde(rename = "vscode")]
    VsCode,
    Exec,
    AppServer,
    SubAgent,
    SubAgentReview,
    SubAgentCompact,
    SubAgentThreadSpawn,
    SubAgentOther,
    Unknown,
}

#[derive(Clone, Serialize)]
#[serde(tag = "mode", content = "kinds", rename_all = "camelCase")]
enum ThreadSourceFilter {
    All,
    Interactive,
    Kinds(Vec<ThreadSourceKind>),
}

impl ThreadSourceFilter {
    fn matches(&self, source: &SessionSource) -> bool {
        match self {
            Self::All => true,
            Self::Interactive => source.is_interactive(),
            Self::Kinds(kinds) => kinds.iter().any(|kind| source.matches_kind(*kind)),
        }
    }
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[allow(clippy::enum_variant_names)]
enum ThreadSortKey {
    CreatedAt,
    UpdatedAt,
    RecencyAt,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum SortDirection {
    Asc,
    Desc,
}

impl SortDirection {
    fn opposite(self) -> Self {
        match self {
            Self::Asc => Self::Desc,
            Self::Desc => Self::Asc,
        }
    }
}

struct EffectiveListQuery {
    cursor: Option<String>,
    limit: usize,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filters: ThreadFilters,
}

impl EffectiveListQuery {
    fn parse(params: &Value) -> Result<Self, CoreError> {
        let section_id = if params.is_null() {
            None
        } else {
            parse_thread_section_id(
                params
                    .as_object()
                    .ok_or(CoreError::InvalidArgument)?
                    .get("sectionId"),
            )?
        };
        let raw = if params.is_null() {
            ThreadListParams::default()
        } else {
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?
        };
        if let (Some(section_id), Some(is_pinned)) = (section_id.as_ref(), raw.is_pinned)
            && section_id.is_some() != is_pinned
        {
            return Err(CoreError::InvalidArgument);
        }
        if raw.parent_thread_id.is_some() && raw.ancestor_thread_id.is_some() {
            return Err(CoreError::InvalidArgument);
        }
        if let Some(parent_thread_id) = raw.parent_thread_id.as_deref() {
            require_uuid(parent_thread_id)?;
        }
        if let Some(ancestor_thread_id) = raw.ancestor_thread_id.as_deref() {
            require_uuid(ancestor_thread_id)?;
        }
        let has_relation_filter =
            raw.parent_thread_id.is_some() || raw.ancestor_thread_id.is_some();

        let model_providers = match raw.model_providers {
            None if has_relation_filter => None,
            None => Some(vec![DEFAULT_MODEL_PROVIDER.to_owned()]),
            Some(providers) if providers.is_empty() => None,
            Some(mut providers) => {
                providers.sort();
                providers.dedup();
                Some(providers)
            }
        };
        let source_filter = match raw.source_kinds {
            None if has_relation_filter => ThreadSourceFilter::All,
            None => ThreadSourceFilter::Interactive,
            Some(source_kinds) if source_kinds.is_empty() => ThreadSourceFilter::Interactive,
            Some(mut source_kinds) => {
                source_kinds.sort();
                source_kinds.dedup();
                ThreadSourceFilter::Kinds(source_kinds)
            }
        };
        let cwd = raw.cwd.map(|cwd| {
            let mut cwd = match cwd {
                ThreadListCwdFilter::One(cwd) => vec![cwd],
                ThreadListCwdFilter::Many(cwd) => cwd,
            };
            cwd.sort();
            cwd.dedup();
            cwd
        });

        Ok(Self {
            cursor: raw.cursor,
            limit: raw
                .limit
                .map(|limit| limit as usize)
                .unwrap_or(DEFAULT_LIMIT)
                .clamp(1, MAX_LIMIT),
            sort_key: raw.sort_key.unwrap_or(ThreadSortKey::CreatedAt),
            sort_direction: raw.sort_direction.unwrap_or(SortDirection::Desc),
            filters: ThreadFilters {
                model_providers,
                source_filter,
                archived: raw.archived.unwrap_or(false),
                is_pinned: raw.is_pinned,
                section_id,
                cwd,
                use_state_db_only: raw.use_state_db_only,
                search_term: raw.search_term,
                parent_thread_id: raw.parent_thread_id,
                ancestor_thread_id: raw.ancestor_thread_id,
            },
        })
    }
}

struct EffectiveSearchQuery {
    cursor: Option<String>,
    limit: usize,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filters: ThreadSearchFilters,
}

impl EffectiveSearchQuery {
    fn parse(params: &Value) -> Result<Self, CoreError> {
        let raw: ThreadSearchParams =
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
        let normalized_search_term = raw.search_term.trim().to_lowercase();
        if normalized_search_term.is_empty() {
            return Err(CoreError::InvalidArgument);
        }

        let source_filter = match raw.source_kinds {
            None => ThreadSourceFilter::Interactive,
            Some(source_kinds) if source_kinds.is_empty() => ThreadSourceFilter::Interactive,
            Some(mut source_kinds) => {
                source_kinds.sort();
                source_kinds.dedup();
                ThreadSourceFilter::Kinds(source_kinds)
            }
        };

        Ok(Self {
            cursor: raw.cursor,
            limit: raw
                .limit
                .map(|limit| limit as usize)
                .unwrap_or(DEFAULT_LIMIT)
                .clamp(1, MAX_LIMIT),
            sort_key: raw.sort_key.unwrap_or(ThreadSortKey::CreatedAt),
            sort_direction: raw.sort_direction.unwrap_or(SortDirection::Desc),
            filters: ThreadSearchFilters {
                source_filter,
                archived: raw.archived.unwrap_or(false),
                normalized_search_term,
            },
        })
    }
}

struct ThreadFilters {
    /// `None` means all providers; `Some` is the exact allow-list.
    model_providers: Option<Vec<String>>,
    source_filter: ThreadSourceFilter,
    archived: bool,
    is_pinned: Option<bool>,
    section_id: Option<Option<String>>,
    cwd: Option<Vec<String>>,
    use_state_db_only: bool,
    search_term: Option<String>,
    parent_thread_id: Option<String>,
    ancestor_thread_id: Option<String>,
}

impl ThreadFilters {
    fn matches(
        &self,
        record: &ThreadRecord,
        archived: bool,
        records: &HashMap<String, ThreadRecord>,
    ) -> bool {
        if archived != self.archived || !record.has_official_metadata() {
            return false;
        }
        if self
            .is_pinned
            .is_some_and(|is_pinned| record.thread.is_pinned != is_pinned)
        {
            return false;
        }
        if self.section_id.as_ref().is_some_and(|section_id| {
            record.thread.section.as_ref().map(|section| &section.id) != section_id.as_ref()
        }) {
            return false;
        }
        if self
            .model_providers
            .as_ref()
            .is_some_and(|providers| !providers.contains(&record.thread.model_provider))
        {
            return false;
        }
        if !self.source_filter.matches(&record.thread.source) {
            return false;
        }
        if self
            .cwd
            .as_ref()
            .is_some_and(|cwd| !cwd.contains(&record.thread.cwd))
        {
            return false;
        }
        if self
            .search_term
            .as_deref()
            .is_some_and(|term| !record.matches_search_term(term))
        {
            return false;
        }
        if self.parent_thread_id.as_ref().is_some_and(|parent_id| {
            !records
                .get(parent_id)
                .is_some_and(ThreadRecord::has_official_metadata)
                || record.thread.parent_thread_id.as_ref() != Some(parent_id)
        }) {
            return false;
        }
        if self.ancestor_thread_id.as_ref().is_some_and(|ancestor_id| {
            !records
                .get(ancestor_id)
                .is_some_and(ThreadRecord::has_official_metadata)
                || !is_descendant_of(record, ancestor_id, records)
        }) {
            return false;
        }
        true
    }

    fn fingerprint(&self) -> Result<String, CoreError> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct FingerprintMaterial<'a> {
            model_providers: &'a Option<Vec<String>>,
            source_filter: &'a ThreadSourceFilter,
            archived: bool,
            is_pinned: Option<bool>,
            section: ThreadSectionFingerprint<'a>,
            cwd: &'a Option<Vec<String>>,
            use_state_db_only: bool,
            search_term: &'a Option<String>,
            parent_thread_id: &'a Option<String>,
            ancestor_thread_id: &'a Option<String>,
        }

        #[derive(Serialize)]
        #[serde(tag = "mode", content = "id", rename_all = "camelCase")]
        enum ThreadSectionFingerprint<'a> {
            All,
            Unsectioned,
            Section(&'a str),
        }

        let section = match self.section_id.as_ref() {
            None => ThreadSectionFingerprint::All,
            Some(None) => ThreadSectionFingerprint::Unsectioned,
            Some(Some(section_id)) => ThreadSectionFingerprint::Section(section_id),
        };
        let bytes = serde_json::to_vec(&FingerprintMaterial {
            model_providers: &self.model_providers,
            source_filter: &self.source_filter,
            archived: self.archived,
            is_pinned: self.is_pinned,
            section,
            cwd: &self.cwd,
            use_state_db_only: self.use_state_db_only,
            search_term: &self.search_term,
            parent_thread_id: &self.parent_thread_id,
            ancestor_thread_id: &self.ancestor_thread_id,
        })
        .map_err(|_| CoreError::InvalidJson)?;

        // FNV-1a is deterministic across platforms and keeps the opaque cursor
        // compact. This is a consistency fingerprint, not an authentication MAC.
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in bytes {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Ok(format!("{hash:016x}"))
    }
}

fn is_descendant_of(
    record: &ThreadRecord,
    ancestor_id: &str,
    records: &HashMap<String, ThreadRecord>,
) -> bool {
    if record.thread.id == ancestor_id {
        return false;
    }

    let mut next_parent_id = record.thread.parent_thread_id.as_deref();
    let mut visited = HashSet::new();
    while let Some(parent_id) = next_parent_id {
        if !visited.insert(parent_id) {
            return false;
        }
        if parent_id == ancestor_id {
            return true;
        }
        next_parent_id = records
            .get(parent_id)
            .filter(|parent| parent.has_official_metadata())
            .and_then(|parent| parent.thread.parent_thread_id.as_deref());
    }
    false
}

struct ThreadSearchFilters {
    source_filter: ThreadSourceFilter,
    archived: bool,
    normalized_search_term: String,
}

impl ThreadSearchFilters {
    fn matches(&self, record: &ThreadRecord, archived: bool) -> bool {
        archived == self.archived && self.source_filter.matches(&record.thread.source)
    }

    fn fingerprint(&self) -> Result<String, CoreError> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct FingerprintMaterial<'a> {
            source_filter: &'a ThreadSourceFilter,
            archived: bool,
            search_term: &'a str,
        }

        let bytes = serde_json::to_vec(&FingerprintMaterial {
            source_filter: &self.source_filter,
            archived: self.archived,
            search_term: &self.normalized_search_term,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        Ok(fingerprint_bytes(&bytes))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CursorV1 {
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filter_fingerprint: String,
    timestamp: i64,
    id: String,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SearchCursorV1 {
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filter_fingerprint: String,
    timestamp: i64,
    id: String,
}

fn compare_records(
    left: &ThreadRecord,
    right: &ThreadRecord,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
) -> Ordering {
    let ordering = left
        .timestamp(sort_key)
        .cmp(&right.timestamp(sort_key))
        .then_with(|| left.thread.id.cmp(&right.thread.id));
    match sort_direction {
        SortDirection::Asc => ordering,
        SortDirection::Desc => ordering.reverse(),
    }
}

fn is_after_cursor(
    record: &ThreadRecord,
    cursor: &CursorV1,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
) -> bool {
    let ordering = record
        .timestamp(sort_key)
        .cmp(&cursor.timestamp)
        .then_with(|| record.thread.id.cmp(&cursor.id));
    match sort_direction {
        SortDirection::Asc => ordering == Ordering::Greater,
        SortDirection::Desc => ordering == Ordering::Less,
    }
}

fn is_after_search_cursor(
    record: &ThreadRecord,
    cursor: &SearchCursorV1,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
) -> bool {
    let ordering = record
        .timestamp(sort_key)
        .cmp(&cursor.timestamp)
        .then_with(|| record.thread.id.cmp(&cursor.id));
    match sort_direction {
        SortDirection::Asc => ordering == Ordering::Greater,
        SortDirection::Desc => ordering == Ordering::Less,
    }
}

fn encode_cursor(
    record: &ThreadRecord,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filter_fingerprint: &str,
) -> Result<String, CoreError> {
    let bytes = serde_json::to_vec(&CursorV1 {
        sort_key,
        sort_direction,
        filter_fingerprint: filter_fingerprint.to_owned(),
        timestamp: record.timestamp(sort_key),
        id: record.thread.id.clone(),
    })
    .map_err(|_| CoreError::InvalidJson)?;
    let mut encoded = String::with_capacity(CURSOR_PREFIX.len() + bytes.len() * 2);
    encoded.push_str(CURSOR_PREFIX);
    for byte in bytes {
        encoded.push(hex_digit(byte >> 4));
        encoded.push(hex_digit(byte & 0x0f));
    }
    Ok(encoded)
}

fn decode_cursor(
    encoded: &str,
    query: &EffectiveListQuery,
    expected_fingerprint: &str,
) -> Result<CursorV1, CoreError> {
    let encoded = encoded
        .strip_prefix(CURSOR_PREFIX)
        .ok_or(CoreError::InvalidArgument)?;
    if encoded.is_empty()
        || !encoded.len().is_multiple_of(2)
        || encoded.len() > MAX_CURSOR_HEX_BYTES
    {
        return Err(CoreError::InvalidArgument);
    }

    let bytes = encoded.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let high = decode_hex_digit(pair[0]).ok_or(CoreError::InvalidArgument)?;
        let low = decode_hex_digit(pair[1]).ok_or(CoreError::InvalidArgument)?;
        decoded.push((high << 4) | low);
    }
    let cursor: CursorV1 =
        serde_json::from_slice(&decoded).map_err(|_| CoreError::InvalidArgument)?;
    if cursor.id.is_empty()
        || cursor.id.len() > 512
        || cursor.filter_fingerprint != expected_fingerprint
        || cursor.sort_key != query.sort_key
        || cursor.sort_direction != query.sort_direction
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(cursor)
}

fn encode_search_cursor(
    record: &ThreadRecord,
    sort_key: ThreadSortKey,
    sort_direction: SortDirection,
    filter_fingerprint: &str,
) -> Result<String, CoreError> {
    let bytes = serde_json::to_vec(&SearchCursorV1 {
        sort_key,
        sort_direction,
        filter_fingerprint: filter_fingerprint.to_owned(),
        timestamp: record.timestamp(sort_key),
        id: record.thread.id.clone(),
    })
    .map_err(|_| CoreError::InvalidJson)?;
    let mut encoded = String::with_capacity(SEARCH_CURSOR_PREFIX.len() + bytes.len() * 2);
    encoded.push_str(SEARCH_CURSOR_PREFIX);
    for byte in bytes {
        encoded.push(hex_digit(byte >> 4));
        encoded.push(hex_digit(byte & 0x0f));
    }
    Ok(encoded)
}

fn decode_search_cursor(
    encoded: &str,
    query: &EffectiveSearchQuery,
    expected_fingerprint: &str,
) -> Result<SearchCursorV1, CoreError> {
    let encoded = encoded
        .strip_prefix(SEARCH_CURSOR_PREFIX)
        .ok_or(CoreError::InvalidArgument)?;
    if encoded.is_empty()
        || !encoded.len().is_multiple_of(2)
        || encoded.len() > MAX_CURSOR_HEX_BYTES
    {
        return Err(CoreError::InvalidArgument);
    }

    let bytes = encoded.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        let high = decode_hex_digit(pair[0]).ok_or(CoreError::InvalidArgument)?;
        let low = decode_hex_digit(pair[1]).ok_or(CoreError::InvalidArgument)?;
        decoded.push((high << 4) | low);
    }
    let cursor: SearchCursorV1 =
        serde_json::from_slice(&decoded).map_err(|_| CoreError::InvalidArgument)?;
    if cursor.id.is_empty()
        || cursor.id.len() > 512
        || cursor.filter_fingerprint != expected_fingerprint
        || cursor.sort_key != query.sort_key
        || cursor.sort_direction != query.sort_direction
    {
        return Err(CoreError::InvalidArgument);
    }
    Ok(cursor)
}

fn fingerprint_bytes(bytes: &[u8]) -> String {
    // FNV-1a is deterministic across platforms and keeps the opaque cursor
    // compact. This is a consistency fingerprint, not an authentication MAC.
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn hex_digit(value: u8) -> char {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    char::from(HEX[usize::from(value)])
}

fn decode_hex_digit(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::super::{ThreadItemKindWire, ThreadItemWire, TurnStatusWire, TurnWire};
    use super::*;
    use serde_json::json;

    const ROOT_ID: &str = "00000000-0000-4000-8000-000000000001";
    const CHILD_ID: &str = "00000000-0000-4000-8000-000000000002";
    const GRANDCHILD_ID: &str = "00000000-0000-4000-8000-000000000003";
    const OTHER_ID: &str = "00000000-0000-4000-8000-000000000004";
    const FORK_ID: &str = "00000000-0000-4000-8000-000000000005";
    const MISSING_ID: &str = "00000000-0000-4000-8000-000000000006";
    const BROKEN_ID: &str = "00000000-0000-4000-8000-000000000007";
    const BELOW_BROKEN_ID: &str = "00000000-0000-4000-8000-000000000008";
    const CYCLE_A_ID: &str = "00000000-0000-4000-8000-000000000009";
    const CYCLE_B_ID: &str = "00000000-0000-4000-8000-00000000000a";
    const OTHER_ROOT_ID: &str = "00000000-0000-4000-8000-00000000000b";
    const FIRST_ID: &str = "00000000-0000-4000-8000-00000000000c";
    const MIDDLE_ID: &str = "00000000-0000-4000-8000-00000000000d";
    const LAST_ID: &str = "00000000-0000-4000-8000-00000000000e";
    const WRONG_SOURCE_ID: &str = "00000000-0000-4000-8000-00000000000f";
    const WRONG_ARCHIVE_ID: &str = "00000000-0000-4000-8000-000000000010";
    const UNRELATED_ID: &str = "00000000-0000-4000-8000-000000000011";
    const FORK_ONLY_ID: &str = "00000000-0000-4000-8000-000000000012";

    fn record(id: &str, title: &str, created_at: i64, source: &str) -> ThreadRecord {
        record_with_source(id, title, created_at, json!(source))
    }

    fn record_with_source(id: &str, title: &str, created_at: i64, source: Value) -> ThreadRecord {
        let metadata = serde_json::from_value(json!({
            "sessionId": "session-tree",
            "preview": format!("{title} preview"),
            "ephemeral": false,
            "modelProvider": "openai",
            "createdAt": created_at,
            "updatedAt": created_at + 1,
            "recencyAt": created_at + 2,
            "path": null,
            "cwd": format!("/workspace/{id}"),
            "cliVersion": "test",
            "source": source,
            "threadSource": "user",
            "parentThreadId": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null
        }))
        .unwrap();
        ThreadRecord::from_metadata(
            id.to_owned(),
            title.to_owned(),
            "workspace".to_owned(),
            Some(metadata),
        )
        .unwrap()
    }

    fn with_lineage(
        mut record: ThreadRecord,
        parent_thread_id: Option<&str>,
        forked_from_id: Option<&str>,
    ) -> ThreadRecord {
        record.thread.parent_thread_id = parent_thread_id.map(str::to_owned);
        record.thread.forked_from_id = forked_from_id.map(str::to_owned);
        record
    }

    fn fork_with_included_items_for_preview_test(
        source: &ThreadRecord,
        included_items: &[ThreadItemWire],
    ) -> ThreadRecord {
        source
            .fork(
                FORK_ID.to_owned(),
                "Fork title must not become preview".to_owned(),
                "workspace".to_owned(),
                Some(1_722_345_700),
                included_items,
            )
            .unwrap()
    }

    fn listed_ids(
        records: &HashMap<String, ThreadRecord>,
        archived_thread_ids: &HashSet<String>,
        params: &Value,
    ) -> Vec<String> {
        let response: Value =
            serde_json::from_slice(&list(records, archived_thread_ids, params).unwrap()).unwrap();
        response["data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|thread| thread["id"].as_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn defaults_filter_sort_and_paginate_with_stable_tuple_cursor() {
        let records = HashMap::from([
            ("a".to_owned(), record("a", "First", 100, "vscode")),
            ("b".to_owned(), record("b", "Second", 200, "vscode")),
            ("c".to_owned(), record("c", "Third", 300, "exec")),
        ]);
        let first: Value =
            serde_json::from_slice(&list(&records, &HashSet::new(), &json!({"limit": 1})).unwrap())
                .unwrap();
        assert_eq!(first["data"][0]["id"], "b");
        assert_eq!(first["data"][0]["status"], json!({"type": "idle"}));
        assert_eq!(first["data"][0]["turns"], json!([]));
        let cursor = first["nextCursor"].as_str().unwrap();
        assert!(cursor.starts_with(CURSOR_PREFIX));

        let second: Value = serde_json::from_slice(
            &list(
                &records,
                &HashSet::new(),
                &json!({"limit": 1, "cursor": cursor}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(second["data"][0]["id"], "a");
        assert!(second["nextCursor"].is_null());
    }

    #[test]
    fn explicit_empty_provider_means_all_and_search_is_case_sensitive() {
        let mut other = record("a", "Needle", 100, "exec");
        other.thread.model_provider = "other".to_owned();
        let records = HashMap::from([("a".to_owned(), other)]);
        let matching: Value = serde_json::from_slice(
            &list(
                &records,
                &HashSet::new(),
                &json!({
                    "modelProviders": [],
                    "sourceKinds": ["exec"],
                    "searchTerm": "Needle"
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(matching["data"].as_array().unwrap().len(), 1);

        let not_matching: Value = serde_json::from_slice(
            &list(
                &records,
                &HashSet::new(),
                &json!({
                    "modelProviders": [],
                    "sourceKinds": ["exec"],
                    "searchTerm": "needle"
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(not_matching["data"].as_array().unwrap().is_empty());
    }

    #[test]
    fn empty_source_kinds_lists_the_complete_official_interactive_set_only() {
        let records = HashMap::from([
            ("cli".to_owned(), record("cli", "CLI", 100, "cli")),
            (
                "vscode".to_owned(),
                record("vscode", "VS Code", 200, "vscode"),
            ),
            (
                "atlas".to_owned(),
                record_with_source("atlas", "Atlas", 300, json!({"custom": "atlas"})),
            ),
            (
                "chatgpt".to_owned(),
                record_with_source("chatgpt", "ChatGPT", 400, json!({"custom": "chatgpt"})),
            ),
            (
                "other-custom".to_owned(),
                record_with_source(
                    "other-custom",
                    "Other custom",
                    500,
                    json!({"custom": "other"}),
                ),
            ),
            (
                "app-server".to_owned(),
                record("app-server", "App server", 600, "appServer"),
            ),
            ("exec".to_owned(), record("exec", "Exec", 700, "exec")),
            (
                "unknown".to_owned(),
                record("unknown", "Unknown", 800, "unknown"),
            ),
        ]);

        for params in [json!({}), json!({"sourceKinds": []})] {
            assert_eq!(
                listed_ids(&records, &HashSet::new(), &params),
                vec!["chatgpt", "atlas", "vscode", "cli"]
            );
        }
        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"sourceKinds": ["cli", "vscode"]}),
            ),
            vec!["vscode", "cli"]
        );
    }

    #[test]
    fn empty_source_kinds_searches_the_complete_official_interactive_set_only() {
        let records = HashMap::from([
            ("cli".to_owned(), record("cli", "CLI", 100, "cli")),
            (
                "vscode".to_owned(),
                record("vscode", "VS Code", 200, "vscode"),
            ),
            (
                "atlas".to_owned(),
                record_with_source("atlas", "Atlas", 300, json!({"custom": "atlas"})),
            ),
            (
                "chatgpt".to_owned(),
                record_with_source("chatgpt", "ChatGPT", 400, json!({"custom": "chatgpt"})),
            ),
            (
                "app-server".to_owned(),
                record("app-server", "App server", 500, "appServer"),
            ),
        ]);
        let visible_content = records
            .keys()
            .map(|id| (id.clone(), vec!["shared phrase".to_owned()]))
            .collect();

        let searched: Value = serde_json::from_slice(
            &search(
                &records,
                &HashSet::new(),
                &visible_content,
                &json!({"searchTerm": "shared", "sourceKinds": []}),
            )
            .unwrap(),
        )
        .unwrap();
        let ids: Vec<&str> = searched["data"]
            .as_array()
            .unwrap()
            .iter()
            .map(|result| result["thread"]["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, vec!["chatgpt", "atlas", "vscode", "cli"]);
    }

    #[test]
    fn list_search_term_uses_the_current_name_after_a_rename() {
        let mut renamed = record(ROOT_ID, "Original title", 100, "appServer");
        renamed.thread.preview = "Conversation preview".to_owned();
        renamed.set_name("Current title".to_owned()).unwrap();
        let records = HashMap::from([(ROOT_ID.to_owned(), renamed)]);

        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({
                    "searchTerm": "Current title",
                    "sourceKinds": ["appServer"]
                }),
            ),
            vec![ROOT_ID]
        );
        assert!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({
                    "searchTerm": "Original title",
                    "sourceKinds": ["appServer"]
                }),
            )
            .is_empty()
        );
    }

    #[test]
    fn cursor_rejects_changed_filters() {
        let records = HashMap::from([
            ("a".to_owned(), record("a", "First", 100, "vscode")),
            ("b".to_owned(), record("b", "Second", 200, "vscode")),
        ]);
        let first: Value =
            serde_json::from_slice(&list(&records, &HashSet::new(), &json!({"limit": 1})).unwrap())
                .unwrap();
        let cursor = first["nextCursor"].as_str().unwrap();
        assert_eq!(
            list(
                &records,
                &HashSet::new(),
                &json!({"limit": 1, "cursor": cursor, "archived": true}),
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn lineage_params_distinguish_omitted_null_and_value_and_reject_two_values() {
        let records = HashMap::from([
            (ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode")),
            (
                CHILD_ID.to_owned(),
                with_lineage(
                    record(CHILD_ID, "Child", 200, "vscode"),
                    Some(ROOT_ID),
                    None,
                ),
            ),
            (
                OTHER_ID.to_owned(),
                record(OTHER_ID, "Other", 300, "vscode"),
            ),
        ]);
        let archived = HashSet::new();

        assert_eq!(
            listed_ids(&records, &archived, &json!({})),
            listed_ids(
                &records,
                &archived,
                &json!({"parentThreadId": null, "ancestorThreadId": null}),
            )
        );
        assert_eq!(
            listed_ids(
                &records,
                &archived,
                &json!({"parentThreadId": ROOT_ID, "ancestorThreadId": null}),
            ),
            vec![CHILD_ID]
        );
        assert_eq!(
            listed_ids(
                &records,
                &archived,
                &json!({"parentThreadId": null, "ancestorThreadId": ROOT_ID}),
            ),
            vec![CHILD_ID]
        );
        assert_eq!(
            list(
                &records,
                &archived,
                &json!({"parentThreadId": ROOT_ID, "ancestorThreadId": ROOT_ID}),
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn lineage_params_reject_malformed_ids_but_unknown_valid_ids_return_empty() {
        let records = HashMap::from([(ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode"))]);
        for invalid in [
            json!({"parentThreadId": ""}),
            json!({"parentThreadId": "not-a-uuid"}),
            json!({"parentThreadId": 42}),
            json!({"ancestorThreadId": " \n "}),
            json!({"ancestorThreadId": []}),
        ] {
            assert_eq!(
                list(&records, &HashSet::new(), &invalid),
                Err(CoreError::InvalidArgument)
            );
        }

        for valid_but_unknown in [
            json!({"parentThreadId": MISSING_ID}),
            json!({"ancestorThreadId": MISSING_ID}),
        ] {
            assert!(
                listed_ids(&records, &HashSet::new(), &valid_but_unknown).is_empty(),
                "{valid_but_unknown}"
            );
        }
    }

    #[test]
    fn lineage_parent_filter_is_exact_direct_and_never_uses_fork_origin() {
        let records = HashMap::from([
            (ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode")),
            (
                CHILD_ID.to_owned(),
                with_lineage(
                    record(CHILD_ID, "Child", 200, "vscode"),
                    Some(ROOT_ID),
                    None,
                ),
            ),
            (
                GRANDCHILD_ID.to_owned(),
                with_lineage(
                    record(GRANDCHILD_ID, "Grandchild", 300, "vscode"),
                    Some(CHILD_ID),
                    None,
                ),
            ),
            (
                FORK_ONLY_ID.to_owned(),
                with_lineage(
                    record(FORK_ONLY_ID, "Fork only", 400, "vscode"),
                    None,
                    Some(ROOT_ID),
                ),
            ),
            (
                OTHER_ID.to_owned(),
                with_lineage(
                    record(OTHER_ID, "Dangling", 500, "vscode"),
                    Some(MISSING_ID),
                    None,
                ),
            ),
        ]);

        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"parentThreadId": ROOT_ID}),
            ),
            vec![CHILD_ID]
        );
        assert!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"parentThreadId": MISSING_ID}),
            )
            .is_empty()
        );
    }

    #[test]
    fn lineage_real_fork_clears_spawn_parent_instead_of_inheriting_it() {
        let source = with_lineage(
            record(CHILD_ID, "Spawned source", 200, "vscode"),
            Some(ROOT_ID),
            None,
        );
        let fork = source
            .fork(
                FORK_ID.to_owned(),
                "Fork".to_owned(),
                "workspace".to_owned(),
                Some(300),
                &[],
            )
            .unwrap();
        assert_eq!(fork.thread.forked_from_id.as_deref(), Some(CHILD_ID));
        assert!(fork.thread.parent_thread_id.is_none());

        let records = HashMap::from([
            (ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode")),
            (CHILD_ID.to_owned(), source),
            (FORK_ID.to_owned(), fork),
        ]);
        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"parentThreadId": ROOT_ID}),
            ),
            vec![CHILD_ID]
        );
        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"ancestorThreadId": ROOT_ID}),
            ),
            vec![CHILD_ID]
        );
    }

    #[test]
    fn lineage_only_query_does_not_apply_interactive_provider_or_source_defaults() {
        let mut spawned = with_lineage(
            record(CHILD_ID, "Spawned child", 200, "vscode"),
            Some(ROOT_ID),
            None,
        );
        spawned.thread.model_provider = "other-provider".to_owned();
        spawned.thread.source = SessionSource::SubAgent(json!({
            "thread_spawn": {
                "parent_thread_id": ROOT_ID,
                "depth": 1
            }
        }));
        let records = HashMap::from([
            (ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode")),
            (CHILD_ID.to_owned(), spawned),
        ]);

        for relation in [
            json!({"parentThreadId": ROOT_ID}),
            json!({"ancestorThreadId": ROOT_ID}),
        ] {
            assert_eq!(
                listed_ids(&records, &HashSet::new(), &relation),
                vec![CHILD_ID]
            );
        }
        assert!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({
                    "parentThreadId": ROOT_ID,
                    "sourceKinds": ["vscode"],
                    "modelProviders": []
                }),
            )
            .is_empty()
        );
    }

    #[test]
    fn lineage_ancestor_filter_walks_depth_and_stops_on_cycles_or_broken_chains() {
        let records = HashMap::from([
            (ROOT_ID.to_owned(), record(ROOT_ID, "Root", 100, "vscode")),
            (
                CHILD_ID.to_owned(),
                with_lineage(
                    record(CHILD_ID, "Child", 200, "vscode"),
                    Some(ROOT_ID),
                    None,
                ),
            ),
            (
                GRANDCHILD_ID.to_owned(),
                with_lineage(
                    record(GRANDCHILD_ID, "Grandchild", 300, "vscode"),
                    Some(CHILD_ID),
                    None,
                ),
            ),
            (
                BROKEN_ID.to_owned(),
                with_lineage(
                    record(BROKEN_ID, "Broken", 400, "vscode"),
                    Some(MISSING_ID),
                    None,
                ),
            ),
            (
                BELOW_BROKEN_ID.to_owned(),
                with_lineage(
                    record(BELOW_BROKEN_ID, "Below broken", 500, "vscode"),
                    Some(BROKEN_ID),
                    None,
                ),
            ),
            (
                CYCLE_A_ID.to_owned(),
                with_lineage(
                    record(CYCLE_A_ID, "Cycle A", 600, "vscode"),
                    Some(CYCLE_B_ID),
                    None,
                ),
            ),
            (
                CYCLE_B_ID.to_owned(),
                with_lineage(
                    record(CYCLE_B_ID, "Cycle B", 700, "vscode"),
                    Some(CYCLE_A_ID),
                    None,
                ),
            ),
        ]);
        let archived = HashSet::new();

        assert_eq!(
            listed_ids(
                &records,
                &archived,
                &json!({
                    "ancestorThreadId": ROOT_ID,
                    "sortKey": "created_at",
                    "sortDirection": "asc"
                }),
            ),
            vec![CHILD_ID, GRANDCHILD_ID]
        );
        assert_eq!(
            listed_ids(&records, &archived, &json!({"ancestorThreadId": BROKEN_ID}),),
            vec![BELOW_BROKEN_ID]
        );
        assert_eq!(
            listed_ids(
                &records,
                &archived,
                &json!({"ancestorThreadId": CYCLE_A_ID}),
            ),
            vec![CYCLE_B_ID]
        );
        assert!(
            listed_ids(
                &records,
                &archived,
                &json!({"ancestorThreadId": MISSING_ID}),
            )
            .is_empty()
        );
    }

    #[test]
    fn lineage_filters_combine_with_archive_source_sort_pagination_and_cursor_identity() {
        let root = record(ROOT_ID, "Root", 50, "vscode");
        let other_root = record(OTHER_ROOT_ID, "Other root", 60, "vscode");
        let mut first = with_lineage(record(FIRST_ID, "First", 100, "exec"), Some(ROOT_ID), None);
        first.thread.model_provider = "other".to_owned();
        let records = HashMap::from([
            (ROOT_ID.to_owned(), root),
            (OTHER_ROOT_ID.to_owned(), other_root),
            (FIRST_ID.to_owned(), first),
            (
                MIDDLE_ID.to_owned(),
                with_lineage(
                    record(MIDDLE_ID, "Middle", 200, "exec"),
                    Some(FIRST_ID),
                    None,
                ),
            ),
            (
                LAST_ID.to_owned(),
                with_lineage(record(LAST_ID, "Last", 300, "exec"), Some(ROOT_ID), None),
            ),
            (
                WRONG_SOURCE_ID.to_owned(),
                with_lineage(
                    record(WRONG_SOURCE_ID, "Wrong source", 150, "vscode"),
                    Some(ROOT_ID),
                    None,
                ),
            ),
            (
                WRONG_ARCHIVE_ID.to_owned(),
                with_lineage(
                    record(WRONG_ARCHIVE_ID, "Wrong archive", 175, "exec"),
                    Some(ROOT_ID),
                    None,
                ),
            ),
            (
                UNRELATED_ID.to_owned(),
                with_lineage(
                    record(UNRELATED_ID, "Unrelated", 125, "exec"),
                    Some(OTHER_ROOT_ID),
                    None,
                ),
            ),
            (
                FORK_ONLY_ID.to_owned(),
                with_lineage(
                    record(FORK_ONLY_ID, "Fork only", 225, "exec"),
                    None,
                    Some(ROOT_ID),
                ),
            ),
        ]);
        let archived = HashSet::from([
            FIRST_ID.to_owned(),
            MIDDLE_ID.to_owned(),
            LAST_ID.to_owned(),
            WRONG_SOURCE_ID.to_owned(),
            UNRELATED_ID.to_owned(),
            FORK_ONLY_ID.to_owned(),
        ]);
        let base_params = json!({
            "ancestorThreadId": ROOT_ID,
            "archived": true,
            "modelProviders": [],
            "sourceKinds": ["exec"],
            "sortKey": "created_at",
            "sortDirection": "asc",
            "limit": 1
        });

        let first_page: Value =
            serde_json::from_slice(&list(&records, &archived, &base_params).unwrap()).unwrap();
        assert_eq!(first_page["data"][0]["id"], FIRST_ID);
        let first_cursor = first_page["nextCursor"].as_str().unwrap();

        let mut second_params = base_params.clone();
        second_params["cursor"] = json!(first_cursor);
        second_params["parentThreadId"] = Value::Null;
        let second_page: Value =
            serde_json::from_slice(&list(&records, &archived, &second_params).unwrap()).unwrap();
        assert_eq!(second_page["data"][0]["id"], MIDDLE_ID);
        let second_cursor = second_page["nextCursor"].as_str().unwrap();

        let mut third_params = base_params.clone();
        third_params["cursor"] = json!(second_cursor);
        let third_page: Value =
            serde_json::from_slice(&list(&records, &archived, &third_params).unwrap()).unwrap();
        assert_eq!(third_page["data"][0]["id"], LAST_ID);
        assert!(third_page["nextCursor"].is_null());

        let mut backwards_params = base_params.clone();
        backwards_params["cursor"] = second_page["backwardsCursor"].clone();
        backwards_params["sortDirection"] = json!("desc");
        let backwards_page: Value =
            serde_json::from_slice(&list(&records, &archived, &backwards_params).unwrap()).unwrap();
        assert_eq!(backwards_page["data"][0]["id"], FIRST_ID);

        for changed_lineage in [
            json!({
                "ancestorThreadId": OTHER_ROOT_ID,
                "archived": true,
                "modelProviders": [],
                "sourceKinds": ["exec"],
                "sortKey": "created_at",
                "sortDirection": "asc",
                "limit": 1,
                "cursor": first_cursor
            }),
            json!({
                "parentThreadId": ROOT_ID,
                "archived": true,
                "modelProviders": [],
                "sourceKinds": ["exec"],
                "sortKey": "created_at",
                "sortDirection": "asc",
                "limit": 1,
                "cursor": first_cursor
            }),
            json!({
                "archived": true,
                "modelProviders": [],
                "sourceKinds": ["exec"],
                "sortKey": "created_at",
                "sortDirection": "asc",
                "limit": 1,
                "cursor": first_cursor
            }),
        ] {
            assert_eq!(
                list(&records, &archived, &changed_lineage),
                Err(CoreError::InvalidArgument)
            );
        }

        let parent_params = json!({
            "parentThreadId": ROOT_ID,
            "archived": true,
            "modelProviders": [],
            "sourceKinds": ["exec"],
            "sortKey": "created_at",
            "sortDirection": "asc",
            "limit": 1
        });
        let parent_page: Value =
            serde_json::from_slice(&list(&records, &archived, &parent_params).unwrap()).unwrap();
        assert_eq!(parent_page["data"][0]["id"], FIRST_ID);
        let parent_cursor = parent_page["nextCursor"].as_str().unwrap();
        let mut parent_second_params = parent_params.clone();
        parent_second_params["ancestorThreadId"] = Value::Null;
        parent_second_params["cursor"] = json!(parent_cursor);
        let parent_second_page: Value =
            serde_json::from_slice(&list(&records, &archived, &parent_second_params).unwrap())
                .unwrap();
        assert_eq!(parent_second_page["data"][0]["id"], LAST_ID);

        let mut changed_parent = parent_params;
        changed_parent["parentThreadId"] = json!(OTHER_ROOT_ID);
        changed_parent["cursor"] = json!(parent_cursor);
        assert_eq!(
            list(&records, &archived, &changed_parent),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn read_returns_complete_metadata_without_turns() {
        let records = HashMap::from([("a".to_owned(), record("a", "First", 100, "vscode"))]);
        let turns = HashMap::new();
        let items = HashMap::new();
        for params in [
            json!({"threadId": "a"}),
            json!({"threadId": "a", "includeTurns": false}),
        ] {
            let response: Value =
                serde_json::from_slice(&read(&records, &[], &turns, &[], &items, &params).unwrap())
                    .unwrap();
            assert_eq!(response["thread"]["name"], "First");
            assert_eq!(response["thread"]["source"], "vscode");
            assert_eq!(response["thread"]["turns"], json!([]));
        }
    }

    #[test]
    fn read_include_turns_projects_ordered_items_for_only_the_requested_thread() {
        let records = HashMap::from([
            ("a".to_owned(), record("a", "First", 100, "vscode")),
            ("b".to_owned(), record("b", "Second", 200, "vscode")),
        ]);
        let turns = HashMap::from([
            (
                "turn-a".to_owned(),
                TurnWire {
                    id: "turn-a".to_owned(),
                    thread_id: "a".to_owned(),
                    status: TurnStatusWire::Completed,
                },
            ),
            (
                "turn-b".to_owned(),
                TurnWire {
                    id: "turn-b".to_owned(),
                    thread_id: "b".to_owned(),
                    status: TurnStatusWire::Completed,
                },
            ),
        ]);
        let items = HashMap::from([
            (
                "user-a".to_owned(),
                ThreadItemWire {
                    id: "user-a".to_owned(),
                    thread_id: "a".to_owned(),
                    turn_id: "turn-a".to_owned(),
                    kind: ThreadItemKindWire::UserMessage,
                    text: "Question".to_owned(),
                },
            ),
            (
                "reasoning-a".to_owned(),
                ThreadItemWire {
                    id: "reasoning-a".to_owned(),
                    thread_id: "a".to_owned(),
                    turn_id: "turn-a".to_owned(),
                    kind: ThreadItemKindWire::Reasoning,
                    text: "Thinking".to_owned(),
                },
            ),
            (
                "assistant-a".to_owned(),
                ThreadItemWire {
                    id: "assistant-a".to_owned(),
                    thread_id: "a".to_owned(),
                    turn_id: "turn-a".to_owned(),
                    kind: ThreadItemKindWire::AssistantMessage,
                    text: "Answer".to_owned(),
                },
            ),
            (
                "user-b".to_owned(),
                ThreadItemWire {
                    id: "user-b".to_owned(),
                    thread_id: "b".to_owned(),
                    turn_id: "turn-b".to_owned(),
                    kind: ThreadItemKindWire::UserMessage,
                    text: "Private other thread".to_owned(),
                },
            ),
        ]);

        let response: Value = serde_json::from_slice(
            &read(
                &records,
                &["turn-b".to_owned(), "turn-a".to_owned()],
                &turns,
                &[
                    "user-b".to_owned(),
                    "assistant-a".to_owned(),
                    "user-a".to_owned(),
                    "reasoning-a".to_owned(),
                ],
                &items,
                &json!({"threadId": "a", "includeTurns": true}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response["thread"]["turns"],
            json!([{
                "id": "turn-a",
                "items": [
                    {
                        "type": "agentMessage",
                        "id": "assistant-a",
                        "text": "Answer",
                        "phase": null,
                        "memoryCitation": null
                    },
                    {
                        "type": "userMessage",
                        "id": "user-a",
                        "clientId": null,
                        "content": [{
                            "type": "text",
                            "text": "Question",
                            "text_elements": []
                        }]
                    }
                ],
                "itemsView": "summary",
                "status": "completed",
                "error": null,
                "startedAt": null,
                "completedAt": null,
                "durationMs": null
            }])
        );
    }

    #[test]
    fn read_include_turns_maps_all_statuses_errors_and_legacy_text_without_fabricated_fields() {
        let records = HashMap::from([("a".to_owned(), record("a", "First", 100, "vscode"))]);
        let turns = HashMap::from([
            (
                "running".to_owned(),
                TurnWire {
                    id: "running".to_owned(),
                    thread_id: "a".to_owned(),
                    status: TurnStatusWire::Running,
                },
            ),
            (
                "failed".to_owned(),
                TurnWire {
                    id: "failed".to_owned(),
                    thread_id: "a".to_owned(),
                    status: TurnStatusWire::Failed,
                },
            ),
            (
                "cancelled".to_owned(),
                TurnWire {
                    id: "cancelled".to_owned(),
                    thread_id: "a".to_owned(),
                    status: TurnStatusWire::Cancelled,
                },
            ),
        ]);
        let items = [
            (
                "tool-call",
                "running",
                ThreadItemKindWire::ToolCall,
                "cargo test",
            ),
            (
                "tool-result",
                "running",
                ThreadItemKindWire::ToolResult,
                "tests passed",
            ),
            (
                "approval",
                "running",
                ThreadItemKindWire::Approval,
                "review requested",
            ),
            (
                "file",
                "running",
                ThreadItemKindWire::FileChange,
                "src/lib.rs updated",
            ),
            (
                "terminal",
                "running",
                ThreadItemKindWire::Terminal,
                "process exited",
            ),
            (
                "error",
                "failed",
                ThreadItemKindWire::Error,
                "provider stopped",
            ),
        ]
        .into_iter()
        .map(|(id, turn_id, kind, text)| {
            (
                id.to_owned(),
                ThreadItemWire {
                    id: id.to_owned(),
                    thread_id: "a".to_owned(),
                    turn_id: turn_id.to_owned(),
                    kind,
                    text: text.to_owned(),
                },
            )
        })
        .collect::<HashMap<_, _>>();

        let response: Value = serde_json::from_slice(
            &read(
                &records,
                &[
                    "cancelled".to_owned(),
                    "running".to_owned(),
                    "failed".to_owned(),
                ],
                &turns,
                &[
                    "tool-call".to_owned(),
                    "tool-result".to_owned(),
                    "approval".to_owned(),
                    "file".to_owned(),
                    "terminal".to_owned(),
                    "error".to_owned(),
                ],
                &items,
                &json!({"threadId": "a", "includeTurns": true}),
            )
            .unwrap(),
        )
        .unwrap();

        assert_eq!(
            response["thread"]["turns"],
            json!([
                {
                    "id": "cancelled",
                    "items": [],
                    "itemsView": "full",
                    "status": "interrupted",
                    "error": null,
                    "startedAt": null,
                    "completedAt": null,
                    "durationMs": null
                },
                {
                    "id": "running",
                    "items": [],
                    "itemsView": "summary",
                    "status": "inProgress",
                    "error": null,
                    "startedAt": null,
                    "completedAt": null,
                    "durationMs": null
                },
                {
                    "id": "failed",
                    "items": [],
                    "itemsView": "summary",
                    "status": "failed",
                    "error": {
                        "message": "provider stopped",
                        "codexErrorInfo": null,
                        "additionalDetails": null
                    },
                    "startedAt": null,
                    "completedAt": null,
                    "durationMs": null
                }
            ])
        );
    }

    #[test]
    fn metadata_update_applies_git_tri_state_atomically() {
        let mut existing = record("a", "First", 100, "vscode");
        existing.thread.git_info = Some(GitInfo {
            sha: Some("abc123".to_owned()),
            branch: Some("main".to_owned()),
            origin_url: Some("https://example.invalid/repository".to_owned()),
        });
        let mut records = HashMap::from([("a".to_owned(), existing)]);

        let response: Value = serde_json::from_slice(
            &metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "gitInfo": {
                        "sha": "  def456  ",
                        "branch": null
                    }
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(response["thread"]["gitInfo"]["sha"], "def456");
        assert!(response["thread"]["gitInfo"]["branch"].is_null());
        assert_eq!(
            response["thread"]["gitInfo"]["originUrl"],
            "https://example.invalid/repository"
        );

        let before_invalid_patch = serde_json::to_value(&records["a"].thread.git_info).unwrap();
        assert_eq!(
            metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "gitInfo": {
                        "sha": "partially-applied",
                        "branch": 42
                    }
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            serde_json::to_value(&records["a"].thread.git_info).unwrap(),
            before_invalid_patch
        );

        assert_eq!(
            metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "gitInfo": null
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
        let pinned_without_git_mutation: Value = serde_json::from_slice(
            &metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "gitInfo": null,
                    "isPinned": true
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            pinned_without_git_mutation["thread"]["gitInfo"],
            before_invalid_patch
        );
        assert_eq!(pinned_without_git_mutation["thread"]["isPinned"], true);

        let cleared: Value = serde_json::from_slice(
            &metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "gitInfo": {
                        "sha": null,
                        "originUrl": null
                    }
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(cleared["thread"]["gitInfo"].is_null());

        for invalid in [
            json!({"threadId": "a"}),
            json!({"threadId": "a", "gitInfo": {}}),
            json!({"threadId": "a", "gitInfo": {"unknown": "value"}}),
            json!({"threadId": "a", "gitInfo": {"sha": " \n "}}),
            json!({"threadId": "a", "gitInfo": {"branch": 42}}),
        ] {
            assert_eq!(
                metadata_update(&mut records, &invalid),
                Err(CoreError::InvalidArgument)
            );
        }
    }

    #[test]
    fn metadata_update_and_list_apply_thread_section_tri_state() {
        let mut records = HashMap::from([
            ("a".to_owned(), record("a", "Pinned", 100, "vscode")),
            ("b".to_owned(), record("b", "Unsectioned", 200, "vscode")),
        ]);

        let pinned: Value = serde_json::from_slice(
            &metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "sectionId": PINNED_THREAD_SECTION_ID
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            pinned["thread"]["section"],
            json!({
                "id": PINNED_THREAD_SECTION_ID,
                "name": PINNED_THREAD_SECTION_NAME
            })
        );
        assert_eq!(pinned["thread"]["isPinned"], true);

        let pinned_page: Value = serde_json::from_slice(
            &list(
                &records,
                &HashSet::new(),
                &json!({"sectionId": PINNED_THREAD_SECTION_ID}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(pinned_page["data"].as_array().unwrap().len(), 1);
        assert_eq!(pinned_page["data"][0]["id"], "a");

        let unsectioned_page: Value = serde_json::from_slice(
            &list(&records, &HashSet::new(), &json!({"sectionId": null})).unwrap(),
        )
        .unwrap();
        assert_eq!(unsectioned_page["data"].as_array().unwrap().len(), 1);
        assert_eq!(unsectioned_page["data"][0]["id"], "b");
        assert!(unsectioned_page["data"][0]["section"].is_null());

        let before_invalid = serde_json::to_value(&records["a"].thread.section).unwrap();
        assert_eq!(
            metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "sectionId": "01984de2-8f74-7c91-a3b2-5c5e937cf319"
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            serde_json::to_value(&records["a"].thread.section).unwrap(),
            before_invalid
        );

        let cleared: Value = serde_json::from_slice(
            &metadata_update(
                &mut records,
                &json!({
                    "threadId": "a",
                    "sectionId": null
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(cleared["thread"]["section"].is_null());
        assert_eq!(cleared["thread"]["isPinned"], false);
    }

    #[test]
    fn section_filter_is_bound_into_thread_list_cursors() {
        let mut first = record("a", "First", 100, "vscode");
        first.thread.section = Some(ThreadSection::pinned());
        first.thread.is_pinned = true;
        let mut second = record("b", "Second", 200, "vscode");
        second.thread.section = Some(ThreadSection::pinned());
        second.thread.is_pinned = true;
        let records = HashMap::from([("a".to_owned(), first), ("b".to_owned(), second)]);
        let archived = HashSet::new();

        let first_page: Value = serde_json::from_slice(
            &list(
                &records,
                &archived,
                &json!({
                    "sectionId": PINNED_THREAD_SECTION_ID,
                    "limit": 1
                }),
            )
            .unwrap(),
        )
        .unwrap();
        let cursor = first_page["nextCursor"].as_str().unwrap();
        assert_eq!(
            list(
                &records,
                &archived,
                &json!({
                    "sectionId": null,
                    "limit": 1,
                    "cursor": cursor
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            list(
                &records,
                &archived,
                &json!({
                    "sectionId": PINNED_THREAD_SECTION_ID,
                    "isPinned": false
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn search_matches_visible_content_case_insensitively_and_paginates() {
        let first = record("a", "Title does not match", 100, "vscode");
        let mut second = record("b", "Second", 200, "cli");
        second.thread.model_provider = "other".to_owned();
        let exec = record("c", "Exec", 300, "exec");
        let archived = record("d", "Archived", 400, "vscode");
        let records = HashMap::from([
            ("a".to_owned(), first),
            ("b".to_owned(), second),
            ("c".to_owned(), exec),
            ("d".to_owned(), archived),
        ]);
        let archived_ids = HashSet::from(["d".to_owned()]);
        let visible_content = HashMap::from([
            (
                "a".to_owned(),
                vec![
                    "Earlier visible text".to_owned(),
                    "Please Inspect the Protocol Bridge now".to_owned(),
                ],
            ),
            (
                "b".to_owned(),
                vec!["A second PROTOCOL BRIDGE mention".to_owned()],
            ),
            ("c".to_owned(), vec!["Protocol bridge from exec".to_owned()]),
            (
                "d".to_owned(),
                vec!["Protocol bridge from archive".to_owned()],
            ),
        ]);

        let first_page: Value = serde_json::from_slice(
            &search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({"searchTerm": " protocol bridge ", "limit": 1}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(first_page["data"][0]["thread"]["id"], "b");
        assert_eq!(
            first_page["data"][0]["snippet"],
            "A second PROTOCOL BRIDGE mention"
        );
        let next_cursor = first_page["nextCursor"].as_str().unwrap();
        assert!(next_cursor.starts_with(SEARCH_CURSOR_PREFIX));
        assert!(
            first_page["backwardsCursor"]
                .as_str()
                .unwrap()
                .starts_with(SEARCH_CURSOR_PREFIX)
        );
        assert_eq!(
            list(&records, &archived_ids, &json!({"cursor": next_cursor})),
            Err(CoreError::InvalidArgument)
        );

        let second_page: Value = serde_json::from_slice(
            &search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({
                    "searchTerm": "PROTOCOL BRIDGE",
                    "sourceKinds": [],
                    "limit": 1,
                    "cursor": next_cursor
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(second_page["data"][0]["thread"]["id"], "a");
        assert_eq!(
            second_page["data"][0]["snippet"],
            "Please Inspect the Protocol Bridge now"
        );
        assert!(second_page["nextCursor"].is_null());

        let backwards_cursor = second_page["backwardsCursor"].as_str().unwrap();
        let backwards: Value = serde_json::from_slice(
            &search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({
                    "searchTerm": "protocol bridge",
                    "limit": 1,
                    "sortDirection": "asc",
                    "cursor": backwards_cursor
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(backwards["data"][0]["thread"]["id"], "b");

        assert_eq!(
            search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({
                    "searchTerm": "different term",
                    "limit": 1,
                    "cursor": next_cursor
                }),
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({"searchTerm": " \n "}),
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn search_honors_explicit_source_and_archive_filters() {
        let records = HashMap::from([
            ("a".to_owned(), record("a", "Interactive", 100, "vscode")),
            ("b".to_owned(), record("b", "Exec", 200, "exec")),
            ("c".to_owned(), record("c", "Archived", 300, "vscode")),
        ]);
        let archived_ids = HashSet::from(["c".to_owned()]);
        let visible_content = HashMap::from([
            ("a".to_owned(), vec!["shared phrase".to_owned()]),
            ("b".to_owned(), vec!["shared phrase".to_owned()]),
            ("c".to_owned(), vec!["shared phrase".to_owned()]),
        ]);

        let exec: Value = serde_json::from_slice(
            &search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({"searchTerm": "shared", "sourceKinds": ["exec"]}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(exec["data"].as_array().unwrap().len(), 1);
        assert_eq!(exec["data"][0]["thread"]["id"], "b");

        let archived: Value = serde_json::from_slice(
            &search(
                &records,
                &archived_ids,
                &visible_content,
                &json!({"searchTerm": "shared", "archived": true}),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(archived["data"].as_array().unwrap().len(), 1);
        assert_eq!(archived["data"][0]["thread"]["id"], "c");
    }

    #[test]
    fn legacy_missing_metadata_replays_without_entering_the_official_directory() {
        let legacy = ThreadRecord::from_metadata(
            "legacy".to_owned(),
            "Legacy task".to_owned(),
            "workspace".to_owned(),
            None,
        )
        .unwrap();
        let records = HashMap::from([("legacy".to_owned(), legacy)]);

        let listed: Value = serde_json::from_slice(
            &list(
                &records,
                &HashSet::new(),
                &json!({
                    "modelProviders": [],
                    "sourceKinds": ["unknown"]
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(listed["data"].as_array().unwrap().is_empty());
        assert_eq!(
            read(
                &records,
                &[],
                &HashMap::new(),
                &[],
                &HashMap::new(),
                &json!({"threadId": "legacy"})
            ),
            Err(CoreError::InvalidArgument)
        );
        let searched: Value = serde_json::from_slice(
            &search(
                &records,
                &HashSet::new(),
                &HashMap::from([(
                    "legacy".to_owned(),
                    vec!["Legacy searchable content".to_owned()],
                )]),
                &json!({
                    "searchTerm": "searchable",
                    "sourceKinds": ["unknown"]
                }),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(searched["data"].as_array().unwrap().is_empty());
    }

    #[test]
    fn official_empty_preview_is_valid_and_listed_while_legacy_stays_hidden() {
        let metadata = serde_json::from_value(json!({
            "sessionId": "new-empty-thread",
            "preview": "",
            "ephemeral": false,
            "modelProvider": "openai",
            "createdAt": 1_722_345_600_i64,
            "updatedAt": 1_722_345_600_i64,
            "recencyAt": 1_722_345_600_i64,
            "path": null,
            "cwd": "/workspace/empty-preview",
            "cliVersion": "0.146.0-alpha.3.1",
            "source": "appServer",
            "threadSource": "user",
            "parentThreadId": null,
            "agentNickname": null,
            "agentRole": null,
            "gitInfo": null
        }))
        .unwrap();
        let official = ThreadRecord::from_metadata(
            ROOT_ID.to_owned(),
            "New thread".to_owned(),
            "workspace".to_owned(),
            Some(metadata),
        )
        .unwrap();
        let legacy = ThreadRecord::from_metadata(
            "legacy".to_owned(),
            "Legacy task".to_owned(),
            "workspace".to_owned(),
            None,
        )
        .unwrap();
        let records = HashMap::from([
            (ROOT_ID.to_owned(), official),
            ("legacy".to_owned(), legacy),
        ]);

        assert_eq!(
            listed_ids(
                &records,
                &HashSet::new(),
                &json!({"sourceKinds": ["appServer"]}),
            ),
            vec![ROOT_ID]
        );
    }

    #[test]
    fn official_activity_uses_caller_timestamps_and_real_user_preview() {
        let mut record = record(ROOT_ID, "Root", 100, "appServer");
        record.thread.preview.clear();

        record
            .start_turn(1_722_345_601, "  Inspect this workspace  ")
            .unwrap();
        let active: Value = serde_json::to_value(&record.thread).unwrap();
        assert_eq!(
            active["status"],
            json!({"type": "active", "activeFlags": []})
        );
        assert_eq!(active["updatedAt"], 1_722_345_601);
        assert_eq!(active["recencyAt"], 1_722_345_601);
        assert_eq!(active["preview"], "Inspect this workspace");

        record
            .finish_turn(1_722_345_602, ThreadTerminalStatus::Completed)
            .unwrap();
        let completed: Value = serde_json::to_value(&record.thread).unwrap();
        assert_eq!(completed["status"], json!({"type": "idle"}));
        assert_eq!(completed["updatedAt"], 1_722_345_602);
        assert_eq!(completed["recencyAt"], 1_722_345_602);

        record
            .start_turn(1_722_345_603, "Retry with diagnostics")
            .unwrap();
        record
            .finish_turn(1_722_345_604, ThreadTerminalStatus::Failed)
            .unwrap();
        let failed: Value = serde_json::to_value(&record.thread).unwrap();
        assert_eq!(failed["status"], json!({"type": "systemError"}));
        assert_eq!(failed["updatedAt"], 1_722_345_604);
        assert_eq!(failed["recencyAt"], 1_722_345_604);

        record
            .start_turn(1_722_345_605, "Cancel this turn")
            .unwrap();
        record
            .finish_turn(1_722_345_606, ThreadTerminalStatus::Cancelled)
            .unwrap();
        let cancelled: Value = serde_json::to_value(&record.thread).unwrap();
        assert_eq!(cancelled["status"], json!({"type": "idle"}));
        assert_eq!(cancelled["updatedAt"], 1_722_345_606);
        assert_eq!(cancelled["recencyAt"], 1_722_345_606);
    }

    #[test]
    fn preview_semantics_multiturn_keeps_the_first_user_message() {
        let mut record = record(ROOT_ID, "Root", 100, "appServer");
        record.thread.preview.clear();

        record.start_turn(103, "  First user request  ").unwrap();
        record
            .finish_turn(104, ThreadTerminalStatus::Completed)
            .unwrap();
        record.start_turn(105, "Second user request").unwrap();

        assert_eq!(record.thread.preview, "First user request");
    }

    #[test]
    fn preview_semantics_fork_uses_first_user_message_from_included_truncated_history() {
        let source = record(ROOT_ID, "Root", 100, "appServer");
        let included_items = vec![
            ThreadItemWire {
                id: "00000000-0000-4000-8000-000000000101".to_owned(),
                thread_id: ROOT_ID.to_owned(),
                turn_id: "00000000-0000-4000-8000-000000000201".to_owned(),
                kind: ThreadItemKindWire::AssistantMessage,
                text: "Earlier assistant context".to_owned(),
            },
            ThreadItemWire {
                id: "00000000-0000-4000-8000-000000000102".to_owned(),
                thread_id: ROOT_ID.to_owned(),
                turn_id: "00000000-0000-4000-8000-000000000202".to_owned(),
                kind: ThreadItemKindWire::UserMessage,
                text: "  First included user request  ".to_owned(),
            },
            ThreadItemWire {
                id: "00000000-0000-4000-8000-000000000103".to_owned(),
                thread_id: ROOT_ID.to_owned(),
                turn_id: "00000000-0000-4000-8000-000000000202".to_owned(),
                kind: ThreadItemKindWire::AssistantMessage,
                text: "Included answer".to_owned(),
            },
            ThreadItemWire {
                id: "00000000-0000-4000-8000-000000000104".to_owned(),
                thread_id: ROOT_ID.to_owned(),
                turn_id: "00000000-0000-4000-8000-000000000203".to_owned(),
                kind: ThreadItemKindWire::UserMessage,
                text: "Later included user request".to_owned(),
            },
        ];

        let fork = fork_with_included_items_for_preview_test(&source, &included_items);

        assert_eq!(fork.thread.preview, "First included user request");
    }

    #[test]
    fn preview_semantics_fork_with_empty_included_history_has_empty_preview() {
        let source = record(ROOT_ID, "Root", 100, "appServer");

        let fork = fork_with_included_items_for_preview_test(&source, &[]);

        assert!(fork.thread.preview.is_empty());
    }

    #[test]
    fn official_fork_uses_supplied_metadata_instead_of_event_sequence() {
        let source = record(ROOT_ID, "Root", 100, "appServer");
        let fork = source
            .fork(
                FORK_ID.to_owned(),
                "Fork".to_owned(),
                "workspace".to_owned(),
                Some(1_722_345_700),
                &[],
            )
            .unwrap();
        let value: Value = serde_json::to_value(&fork.thread).unwrap();
        assert_eq!(value["createdAt"], 1_722_345_700_i64);
        assert_eq!(value["updatedAt"], 1_722_345_700_i64);
        assert_eq!(value["recencyAt"], 1_722_345_700_i64);
        assert_eq!(value["forkedFromId"], ROOT_ID);
    }
}
