use super::{CoreError, TurnStatusWire, turn_start};
use codex_protocol::models::ResponseItem;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Default)]
pub(super) struct RawHistoryIndex {
    turns: HashMap<String, RawTurnHistory>,
    compactions: HashMap<String, CompactionCheckpoint>,
    injections: HashMap<String, Vec<InjectedHistoryBatch>>,
}

#[derive(Clone, Default)]
struct RawTurnHistory {
    entries: Vec<RawHistoryEntry>,
    completions: Vec<RawHistoryCompletion>,
    response_ids: HashSet<String>,
    ended: bool,
}

#[derive(Clone)]
struct CompactionCheckpoint {
    replacement_items: Vec<String>,
}

#[derive(Clone)]
struct InjectedHistoryBatch {
    after_turn_id: Option<String>,
    items: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InjectHistoryCommand {
    kind: String,
    thread_id: String,
    #[serde(default)]
    after_turn_id: Option<String>,
    items: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryInjectedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    after_turn_id: Option<&'a str>,
    items: &'a [String],
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawHistoryEntry {
    order: u64,
    source: RawHistorySource,
    item_json: String,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
enum RawHistorySource {
    Provider,
    LocalTool,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawHistoryCompletion {
    response_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    usage: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    end_turn: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawHistoryCommitCommand {
    kind: String,
    thread_id: String,
    turn_id: String,
    expected_next_order: u64,
    entries: Vec<RawHistoryEntry>,
    #[serde(default)]
    completion: Option<RawHistoryCompletion>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RawHistoryCommittedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    turn_id: &'a str,
    expected_next_order: u64,
    entries: &'a [RawHistoryEntry],
    completion: Option<&'a RawHistoryCompletion>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompactHistoryCommitCommand {
    kind: String,
    thread_id: String,
    turn_id: String,
    item_id: String,
    replacement_items: Vec<String>,
    response_id: String,
    #[serde(default)]
    usage: Option<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CompactHistoryCommittedEvent<'a> {
    sequence: u64,
    kind: &'static str,
    thread_id: &'a str,
    turn_id: &'a str,
    item_id: &'a str,
    replacement_items: &'a [String],
    response_id: &'a str,
    usage: Option<&'a Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PriorInputItemsParams {
    thread_id: String,
    #[serde(default)]
    before_turn_id: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PriorInputItemsResult {
    thread_id: String,
    through_turn_id: Option<String>,
    items: Vec<String>,
    completeness: PriorInputCompleteness,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum PriorInputCompleteness {
    Complete,
    PartialLegacy,
    LegacyUnavailable,
}

impl RawHistoryIndex {
    pub(super) fn inject(
        &mut self,
        thread_ids: &HashSet<String>,
        turns: &HashMap<String, super::TurnWire>,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: InjectHistoryCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        if command.kind != "thread.inject-items"
            || !thread_ids.contains(&command.thread_id)
            || command.items.is_empty()
            || command.after_turn_id.as_ref().is_some_and(|turn_id| {
                turns
                    .get(turn_id)
                    .is_none_or(|turn| turn.thread_id != command.thread_id)
            })
        {
            return Err(CoreError::InvalidArgument);
        }
        for item_json in &command.items {
            let value: Value =
                serde_json::from_str(item_json).map_err(|_| CoreError::InvalidArgument)?;
            let item: ResponseItem =
                serde_json::from_value(value.clone()).map_err(|_| CoreError::InvalidArgument)?;
            if !value.is_object() || matches!(item, ResponseItem::Other) {
                return Err(CoreError::InvalidArgument);
            }
        }

        let event = serde_json::to_vec(&HistoryInjectedEvent {
            sequence,
            kind: "threadItemsInjected",
            thread_id: &command.thread_id,
            after_turn_id: command.after_turn_id.as_deref(),
            items: &command.items,
        })
        .map_err(|_| CoreError::InvalidJson)?;
        self.injections
            .entry(command.thread_id)
            .or_default()
            .push(InjectedHistoryBatch {
                after_turn_id: command.after_turn_id,
                items: command.items,
            });
        Ok(vec![event])
    }

    pub(super) fn commit_compaction(
        &mut self,
        turn_threads: &HashMap<String, String>,
        turns: &mut HashMap<String, super::TurnWire>,
        completed_turn_ids: &mut HashSet<String>,
        items: &HashMap<String, super::ThreadItemWire>,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: CompactHistoryCommitCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        if command.kind != "turn.compact-history.commit"
            || command.thread_id.is_empty()
            || command.turn_id.is_empty()
            || command.item_id.is_empty()
            || command.replacement_items.is_empty()
            || command.response_id.trim().is_empty()
            || command
                .usage
                .as_ref()
                .is_some_and(|usage| !usage.is_object())
            || turn_threads.get(&command.turn_id) != Some(&command.thread_id)
            || items.get(&command.item_id).is_none_or(|item| {
                item.thread_id != command.thread_id
                    || item.turn_id != command.turn_id
                    || item.kind != super::ThreadItemKindWire::ContextCompaction
            })
            || turns
                .get(&command.turn_id)
                .is_none_or(|turn| turn.status != TurnStatusWire::Running)
            || self.compactions.contains_key(&command.turn_id)
        {
            return Err(CoreError::InvalidArgument);
        }
        for item_json in &command.replacement_items {
            let item: ResponseItem =
                serde_json::from_str(item_json).map_err(|_| CoreError::InvalidArgument)?;
            if matches!(item, ResponseItem::Other) {
                return Err(CoreError::InvalidArgument);
            }
        }
        let event = serde_json::to_vec(&CompactHistoryCommittedEvent {
            sequence,
            kind: "turnCompactionCommitted",
            thread_id: &command.thread_id,
            turn_id: &command.turn_id,
            item_id: &command.item_id,
            replacement_items: &command.replacement_items,
            response_id: &command.response_id,
            usage: command.usage.as_ref(),
        })
        .map_err(|_| CoreError::InvalidJson)?;
        self.compactions.insert(
            command.turn_id.clone(),
            CompactionCheckpoint {
                replacement_items: command.replacement_items,
            },
        );
        completed_turn_ids.insert(command.turn_id.clone());
        if let Some(turn) = turns.get_mut(&command.turn_id) {
            turn.status = TurnStatusWire::Completed;
        }
        Ok(vec![event])
    }

    pub(super) fn commit(
        &mut self,
        turn_threads: &HashMap<String, String>,
        turns: &mut HashMap<String, super::TurnWire>,
        completed_turn_ids: &mut HashSet<String>,
        input: &[u8],
        sequence: u64,
    ) -> Result<Vec<Vec<u8>>, CoreError> {
        let command: RawHistoryCommitCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        if command.kind != "turn.raw-history.commit"
            || command.thread_id.is_empty()
            || command.turn_id.is_empty()
            || turn_threads.get(&command.turn_id) != Some(&command.thread_id)
            || (command.entries.is_empty() && command.completion.is_none())
        {
            return Err(CoreError::InvalidArgument);
        }

        let current = self.turns.get(&command.turn_id);
        let next_order = u64::try_from(current.map_or(0, |history| history.entries.len()))
            .map_err(|_| CoreError::InvalidArgument)?;
        if command.expected_next_order != next_order || current.is_some_and(|history| history.ended)
        {
            return Err(CoreError::InvalidArgument);
        }
        for (offset, entry) in command.entries.iter().enumerate() {
            let offset = u64::try_from(offset).map_err(|_| CoreError::InvalidArgument)?;
            if entry.order
                != command
                    .expected_next_order
                    .checked_add(offset)
                    .ok_or(CoreError::InvalidArgument)?
            {
                return Err(CoreError::InvalidArgument);
            }
            let validated: Value =
                serde_json::from_str(&entry.item_json).map_err(|_| CoreError::InvalidArgument)?;
            if !validated.is_object() {
                return Err(CoreError::InvalidArgument);
            }
        }
        if let Some(completion) = &command.completion
            && (completion.response_id.trim().is_empty()
                || completion
                    .usage
                    .as_ref()
                    .is_some_and(|usage| !usage.is_object())
                || current
                    .is_some_and(|history| history.response_ids.contains(&completion.response_id)))
        {
            return Err(CoreError::InvalidArgument);
        }

        let event = serde_json::to_vec(&RawHistoryCommittedEvent {
            sequence,
            kind: "turnRawHistoryCommitted",
            thread_id: &command.thread_id,
            turn_id: &command.turn_id,
            expected_next_order: command.expected_next_order,
            entries: &command.entries,
            completion: command.completion.as_ref(),
        })
        .map_err(|_| CoreError::InvalidJson)?;

        let history = self.turns.entry(command.turn_id.clone()).or_default();
        history.entries.extend(command.entries);
        if let Some(completion) = command.completion {
            let ends_turn = completion.end_turn == Some(true);
            history.response_ids.insert(completion.response_id.clone());
            history.completions.push(completion);
            if ends_turn {
                history.ended = true;
                completed_turn_ids.insert(command.turn_id.clone());
                if let Some(turn) = turns.get_mut(&command.turn_id)
                    && turn.status == TurnStatusWire::Running
                {
                    turn.status = TurnStatusWire::Completed;
                }
            }
        }
        Ok(vec![event])
    }

    pub(super) fn prior_input_items(
        &self,
        thread_ids: &HashSet<String>,
        turn_order: &[String],
        turns: &HashMap<String, super::TurnWire>,
        stable_turn_starts: &HashMap<String, turn_start::StartedTurn>,
        params: &Value,
    ) -> Result<Vec<u8>, CoreError> {
        let params: PriorInputItemsParams =
            serde_json::from_value(params.clone()).map_err(|_| CoreError::InvalidArgument)?;
        if params.thread_id.is_empty() || !thread_ids.contains(&params.thread_id) {
            return Err(CoreError::InvalidArgument);
        }
        if let Some(before_turn_id) = &params.before_turn_id
            && turns
                .get(before_turn_id)
                .is_none_or(|turn| turn.thread_id != params.thread_id)
        {
            return Err(CoreError::InvalidArgument);
        }

        let mut selected_turns = Vec::new();
        for turn_id in turn_order {
            if params.before_turn_id.as_ref() == Some(turn_id) {
                break;
            }
            if turns
                .get(turn_id)
                .is_some_and(|turn| turn.thread_id == params.thread_id)
            {
                selected_turns.push(turn_id);
            }
        }

        let mut items = Vec::new();
        let mut is_complete = true;
        let mut has_exact_item = false;
        let mut has_stable_turn = false;
        let mut through_turn_id = None;
        let latest_compaction = selected_turns
            .iter()
            .enumerate()
            .rev()
            .find(|(_, turn_id)| self.compactions.contains_key(**turn_id));
        let start_index = if let Some((index, turn_id)) = latest_compaction {
            let checkpoint = self
                .compactions
                .get(*turn_id)
                .ok_or(CoreError::InvalidArgument)?;
            items.extend(checkpoint.replacement_items.iter().cloned());
            has_exact_item = true;
            through_turn_id = Some((*turn_id).clone());
            index + 1
        } else {
            self.append_injections(&params.thread_id, None, &mut items);
            has_exact_item |= !items.is_empty();
            0
        };
        if let Some((_, turn_id)) = latest_compaction {
            let before = items.len();
            self.append_injections(&params.thread_id, Some(turn_id), &mut items);
            has_exact_item |= items.len() != before;
        }
        for turn_id in selected_turns.iter().skip(start_index) {
            let stable_start = stable_turn_starts.get(*turn_id);
            has_stable_turn |= stable_start.is_some();
            if turns
                .get(*turn_id)
                .is_none_or(|turn| turn.status != TurnStatusWire::Completed)
            {
                is_complete = false;
                continue;
            }
            let Some(history) = self.turns.get(*turn_id).filter(|history| history.ended) else {
                is_complete = false;
                continue;
            };

            through_turn_id = Some((*turn_id).clone());
            match stable_start {
                Some(started) => match stable_user_response_item(started.raw_params()) {
                    StableUserMapping::Exact(Some(item)) => {
                        has_exact_item = true;
                        items.push(item);
                    }
                    StableUserMapping::Exact(None) => {}
                    StableUserMapping::Unavailable => is_complete = false,
                },
                None => is_complete = false,
            }
            has_exact_item |= !history.entries.is_empty();
            items.extend(history.entries.iter().map(|entry| entry.item_json.clone()));
            let before = items.len();
            self.append_injections(&params.thread_id, Some(turn_id), &mut items);
            has_exact_item |= items.len() != before;
        }

        let completeness = if is_complete {
            PriorInputCompleteness::Complete
        } else if has_exact_item || has_stable_turn {
            PriorInputCompleteness::PartialLegacy
        } else {
            PriorInputCompleteness::LegacyUnavailable
        };
        serde_json::to_vec(&PriorInputItemsResult {
            thread_id: params.thread_id,
            through_turn_id,
            items,
            completeness,
        })
        .map_err(|_| CoreError::InvalidJson)
    }

    pub(super) fn remove_turn(&mut self, turn_id: &str) {
        self.turns.remove(turn_id);
        self.compactions.remove(turn_id);
        for batches in self.injections.values_mut() {
            batches.retain(|batch| batch.after_turn_id.as_deref() != Some(turn_id));
        }
    }

    fn append_injections(
        &self,
        thread_id: &str,
        after_turn_id: Option<&String>,
        output: &mut Vec<String>,
    ) {
        let Some(batches) = self.injections.get(thread_id) else {
            return;
        };
        for batch in batches {
            if batch.after_turn_id.as_deref() == after_turn_id.map(String::as_str) {
                output.extend(batch.items.iter().cloned());
            }
        }
    }
}

pub(super) fn make_thread_read_truthful(
    response: Vec<u8>,
    raw_history: &RawHistoryIndex,
) -> Result<Vec<u8>, CoreError> {
    let mut response: Value =
        serde_json::from_slice(&response).map_err(|_| CoreError::InvalidJson)?;
    let turns = response
        .get_mut("thread")
        .and_then(|thread| thread.get_mut("turns"))
        .and_then(Value::as_array_mut)
        .ok_or(CoreError::InvalidJson)?;
    for turn in turns {
        let turn_id = turn
            .get("id")
            .and_then(Value::as_str)
            .ok_or(CoreError::InvalidJson)?
            .to_owned();
        let items = turn
            .get_mut("items")
            .and_then(Value::as_array_mut)
            .ok_or(CoreError::InvalidJson)?;
        let has_agent_message = items
            .iter()
            .any(|item| item.get("type").and_then(Value::as_str) == Some("agentMessage"));
        if !has_agent_message && let Some(history) = raw_history.turns.get(&turn_id) {
            items.extend(
                history
                    .entries
                    .iter()
                    .filter_map(|entry| project_agent_message(&turn_id, entry)),
            );
        }
        if turn.get("itemsView").and_then(Value::as_str) == Some("full") {
            turn.as_object_mut()
                .ok_or(CoreError::InvalidJson)?
                .insert("itemsView".to_owned(), Value::String("summary".to_owned()));
        }
    }
    serde_json::to_vec(&response).map_err(|_| CoreError::InvalidJson)
}

fn project_agent_message(turn_id: &str, entry: &RawHistoryEntry) -> Option<Value> {
    let item: Value = serde_json::from_str(&entry.item_json).ok()?;
    if item.get("type").and_then(Value::as_str) != Some("message")
        || item.get("role").and_then(Value::as_str) != Some("assistant")
    {
        return None;
    }
    let content = item.get("content")?.as_array()?;
    if content.is_empty()
        || content.iter().any(|part| {
            part.get("type").and_then(Value::as_str) != Some("output_text")
                || part.get("text").and_then(Value::as_str).is_none()
        })
    {
        return None;
    }
    let text = content
        .iter()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<String>();
    Some(serde_json::json!({
        "type": "agentMessage",
        "id": format!("raw-history-{turn_id}-{}", entry.order),
        "text": text,
        "phase": null,
        "memoryCitation": null,
    }))
}

enum StableUserMapping {
    Exact(Option<String>),
    Unavailable,
}

fn stable_user_response_item(params: &Value) -> StableUserMapping {
    let Some(inputs) = params.get("input").and_then(Value::as_array) else {
        return StableUserMapping::Unavailable;
    };
    if inputs.is_empty() {
        return StableUserMapping::Exact(None);
    }
    let mut content = Vec::with_capacity(inputs.len());
    for input in inputs {
        let Some(input) = input.as_object() else {
            return StableUserMapping::Unavailable;
        };
        if input.get("type").and_then(Value::as_str) != Some("text")
            || input
                .get("text_elements")
                .is_some_and(|elements| elements.as_array().is_none_or(|items| !items.is_empty()))
        {
            return StableUserMapping::Unavailable;
        }
        let Some(text) = input.get("text").and_then(Value::as_str) else {
            return StableUserMapping::Unavailable;
        };
        content.push(UserInputText::new(text));
    }
    let candidate = UserResponseItem {
        kind: "message",
        role: "user",
        content,
    };
    let Ok(item_json) = serde_json::to_string(&candidate) else {
        return StableUserMapping::Unavailable;
    };
    let Ok(item) = serde_json::from_str::<ResponseItem>(&item_json) else {
        return StableUserMapping::Unavailable;
    };
    if matches!(item, ResponseItem::Other) {
        StableUserMapping::Unavailable
    } else {
        StableUserMapping::Exact(Some(item_json))
    }
}

#[derive(Serialize)]
struct UserResponseItem<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    role: &'static str,
    content: Vec<UserInputText<'a>>,
}

#[derive(Serialize)]
struct UserInputText<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    text: &'a str,
}

impl<'a> UserInputText<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            kind: "input_text",
            text,
        }
    }
}
