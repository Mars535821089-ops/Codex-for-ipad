use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

mod git_diff;
mod git_worker;
mod model_catalog;
mod official_provider;
mod session;
mod storage;

const ABI_VERSION: u32 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreError {
    InvalidArgument,
    InvalidJson,
    UnsupportedCommand,
    Storage,
    Network,
    Cancelled,
}

#[derive(Deserialize)]
struct CoreCommand {
    kind: String,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
}

#[derive(Deserialize)]
struct CoreRequest {
    #[serde(default)]
    id: Option<CoreRequestId>,
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(untagged)]
enum CoreRequestId {
    String(String),
    Integer(i64),
}

#[derive(Deserialize)]
struct StorageOpenCommand {
    #[serde(rename = "databasePath")]
    database_path: String,
    #[serde(rename = "snapshotDirectory")]
    snapshot_directory: String,
}

#[derive(Deserialize)]
struct StorageRestoreCommand {
    #[serde(rename = "databasePath")]
    database_path: String,
    #[serde(rename = "snapshotDirectory")]
    snapshot_directory: String,
    #[serde(rename = "snapshotName")]
    snapshot_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentKeyInput {
    websocket_url: String,
    account_id: String,
    #[serde(default)]
    app_server_client_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentUpsertCommand {
    websocket_url: String,
    account_id: String,
    #[serde(default)]
    app_server_client_name: Option<String>,
    server_id: String,
    environment_id: String,
    server_name: String,
    updated_at: i64,
    #[serde(default)]
    remote_control_enabled: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentSetEnabledCommand {
    websocket_url: String,
    account_id: String,
    #[serde(default)]
    app_server_client_name: Option<String>,
    enabled: bool,
    updated_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EnrollmentOutput {
    websocket_url: String,
    account_id: String,
    app_server_client_name: String,
    server_id: String,
    environment_id: String,
    server_name: String,
    updated_at: i64,
    remote_control_enabled: Option<bool>,
}

impl From<storage::StoredEnrollment> for EnrollmentOutput {
    fn from(value: storage::StoredEnrollment) -> Self {
        Self {
            websocket_url: value.key.websocket_url,
            account_id: value.key.account_id,
            app_server_client_name: value.key.app_server_client_name,
            server_id: value.server_id,
            environment_id: value.environment_id,
            server_name: value.server_name,
            updated_at: value.updated_at,
            remote_control_enabled: value.remote_control_enabled,
        }
    }
}

#[derive(Serialize)]
struct CoreEvent<'a> {
    sequence: u64,
    kind: &'static str,
    #[serde(rename = "requestId")]
    request_id: &'a str,
}

pub struct CodexCore {
    next_sequence: u64,
    events: VecDeque<Vec<u8>>,
    model_catalog: model_catalog::ModelCatalog,
    session: session::SessionIndex,
    storage: Option<storage::Storage>,
}

impl Default for CodexCore {
    fn default() -> Self {
        Self {
            next_sequence: 1,
            events: VecDeque::new(),
            model_catalog: model_catalog::ModelCatalog::default(),
            session: session::SessionIndex::default(),
            storage: None,
        }
    }
}

impl CodexCore {
    pub fn request(&mut self, input: &[u8]) -> Result<Vec<u8>, CoreError> {
        let request: CoreRequest =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        let request_id = request.id.clone();
        if request.method == "gitDiffToRemote" {
            let result = git_diff::request(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "gitWorker/read" {
            let result = git_worker::request(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if matches!(
            request.method.as_str(),
            "model/list" | "modelProvider/capabilities/read"
        ) {
            let result = self
                .model_catalog
                .request(&request.method, &request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "threadSection/list" {
            let storage = self.storage.as_ref().ok_or(CoreError::UnsupportedCommand)?;
            let result = storage.list_thread_sections(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "remote_control.enrollment.load" {
            let params: EnrollmentKeyInput =
                serde_json::from_value(request.params).map_err(|_| CoreError::InvalidArgument)?;
            let key = enrollment_key(
                params.websocket_url,
                params.account_id,
                params.app_server_client_name,
            )?;
            let storage = self.storage.as_ref().ok_or(CoreError::InvalidArgument)?;
            let enrollment = storage.load_enrollment(&key)?.map(EnrollmentOutput::from);
            let result = serde_json::to_vec(&serde_json::json!({
                "enrollment": enrollment,
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/start" {
            let (command, thread_id) =
                self.session.prepare_request_thread_start(&request.params)?;
            self.submit(&command)?;
            self.session.subscribe_thread(&thread_id)?;
            let result = self
                .session
                .request("thread/resume", &serde_json::json!({"threadId": thread_id}))?;
            let result_value: serde_json::Value =
                serde_json::from_slice(&result).map_err(|_| CoreError::InvalidJson)?;
            let thread = result_value
                .get("thread")
                .cloned()
                .ok_or(CoreError::InvalidJson)?;
            self.events.push_back(
                serde_json::to_vec(&serde_json::json!({
                    "method": "thread/started",
                    "params": {
                        "thread": thread,
                    },
                }))
                .map_err(|_| CoreError::InvalidJson)?,
            );
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "turn/start" {
            let (command, result) = self.session.prepare_request_turn_start(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), result)?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/compact/start" {
            let command = self
                .session
                .prepare_request_compact_start(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/inject_items" {
            let command = self.session.prepare_request_inject_items(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/shellCommand" {
            let command = self
                .session
                .prepare_request_shell_command(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/approveGuardianDeniedAction" {
            let command = self
                .session
                .prepare_request_approve_guardian_denied_action(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            if let Some(command) = command {
                self.submit(&command)?;
            }
            return Ok(response);
        }
        if request.method == "thread/unsubscribe" {
            let result = self.session.unsubscribe_thread(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/loaded/list" {
            let result = self.session.loaded_threads(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/resume" {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            let result = self.session.request(&request.method, &request.params)?;
            self.session.subscribe_thread(&thread_id)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/prior-input-items" {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            let result = self.session.request(
                "thread/prior-input-items",
                &request.params,
            )?;
            self.session.subscribe_thread(&thread_id)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/settings/update" {
            let command = self
                .session
                .prepare_thread_settings_update(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            if let Some(command) = command {
                self.submit(&command)?;
            }
            return Ok(response);
        }
        if request.method == "thread/metadata/update" {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|thread_id| !thread_id.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            if let Some(section_id) = request.params.get("sectionId") {
                let storage = self.storage.as_ref().ok_or(CoreError::UnsupportedCommand)?;
                match section_id {
                    serde_json::Value::Null => {}
                    serde_json::Value::String(section_id)
                        if !section_id.trim().is_empty()
                            && storage.thread_section_exists(section_id)? => {}
                    _ => return Err(CoreError::InvalidArgument),
                }
            }
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind": "thread.metadata-update",
                "params": request.params,
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = self
                .session
                .request("thread/read", &serde_json::json!({"threadId": thread_id}))?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/memoryMode/set" {
            let command = self
                .session
                .prepare_request_memory_mode_set(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), b"{}".to_vec())?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/rollback" {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|thread_id| !thread_id.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            let num_turns = request
                .params
                .get("numTurns")
                .and_then(serde_json::Value::as_u64)
                .filter(|num_turns| *num_turns > 0)
                .ok_or(CoreError::InvalidArgument)?;
            if request
                .params
                .as_object()
                .is_none_or(|params| params.len() != 2)
            {
                return Err(CoreError::InvalidArgument);
            }
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind": "thread.rollback",
                "threadId": thread_id,
                "numTurns": num_turns,
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = self.session.request(
                "thread/read",
                &serde_json::json!({
                    "threadId": thread_id,
                    "includeTurns": true,
                }),
            )?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/revert" {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|thread_id| !thread_id.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            let before_turn_id = request
                .params
                .get("beforeTurnId")
                .and_then(serde_json::Value::as_str)
                .filter(|turn_id| !turn_id.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            if request
                .params
                .as_object()
                .is_none_or(|params| params.len() != 2)
            {
                return Err(CoreError::InvalidArgument);
            }
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind": "thread.revert",
                "threadId": thread_id,
                "beforeTurnId": before_turn_id,
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = self.session.thread_revert_response(&thread_id)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/queue/list" {
            let result = self.session.queue_list(&request.params)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/queue/add" {
            let object = request
                .params
                .as_object()
                .ok_or(CoreError::InvalidArgument)?;
            if object.len() != 3 {
                return Err(CoreError::InvalidArgument);
            }
            let thread_id = object
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let input = object
                .get("input")
                .and_then(serde_json::Value::as_array)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let client_user_message_id = object
                .get("clientUserMessageId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let queued_submission_id = self.session.new_queue_submission_id();
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind":"thread.queue.add",
                "threadId":thread_id,
                "queuedSubmission": {
                    "id": queued_submission_id,
                    "input": input,
                    "clientUserMessageId": client_user_message_id,
                }
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = self
                .session
                .queue_submission(thread_id, &queued_submission_id)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/queue/update" {
            let object = request
                .params
                .as_object()
                .ok_or(CoreError::InvalidArgument)?;
            if object.len() != 3 {
                return Err(CoreError::InvalidArgument);
            }
            let thread_id = object
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let queued_submission_id = object
                .get("queuedSubmissionId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let input = object
                .get("input")
                .and_then(serde_json::Value::as_array)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind":"thread.queue.update","threadId":thread_id,
                "queuedSubmissionId":queued_submission_id,"input":input
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = self
                .session
                .queue_submission(thread_id, queued_submission_id)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/queue/delete" {
            let object = request
                .params
                .as_object()
                .ok_or(CoreError::InvalidArgument)?;
            if object.len() != 2 {
                return Err(CoreError::InvalidArgument);
            }
            let thread_id = object
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let queued_submission_id = object
                .get("queuedSubmissionId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let existed = self
                .session
                .queue_list(&serde_json::json!({"threadId":thread_id}))?;
            let existed: serde_json::Value =
                serde_json::from_slice(&existed).map_err(|_| CoreError::InvalidJson)?;
            let deleted = existed["data"]
                .as_array()
                .is_some_and(|items| items.iter().any(|item| item["id"] == queued_submission_id));
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind":"thread.queue.delete","threadId":thread_id,
                "queuedSubmissionId":queued_submission_id
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            if deleted {
                self.submit(&internal)?;
            }
            let result = serde_json::to_vec(&serde_json::json!({"deleted":deleted}))
                .map_err(|_| CoreError::InvalidJson)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if request.method == "thread/queue/reorder" {
            let object = request
                .params
                .as_object()
                .ok_or(CoreError::InvalidArgument)?;
            if object.len() != 2 {
                return Err(CoreError::InvalidArgument);
            }
            let thread_id = object
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or(CoreError::InvalidArgument)?;
            let ids = object
                .get("queuedSubmissionIds")
                .and_then(serde_json::Value::as_array)
                .ok_or(CoreError::InvalidArgument)?;
            let internal = serde_json::to_vec(&serde_json::json!({
                "kind":"thread.queue.reorder","threadId":thread_id,
                "queuedSubmissionIds":ids
            }))
            .map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            return encode_request_result(request_id.as_ref(), b"{}".to_vec());
        }
        if request.method == "thread/queue/start" {
            let (command, result) = self.session.prepare_request_queue_start(&request.params)?;
            let response = encode_request_result(request_id.as_ref(), result)?;
            self.submit(&command)?;
            return Ok(response);
        }
        if request.method == "thread/fork" {
            let (command, thread_id, exclude_turns) =
                self.session.prepare_request_thread_fork(&request.params)?;
            self.submit(&command)?;
            self.session.subscribe_thread(&thread_id)?;
            let mut result: serde_json::Value = serde_json::from_slice(
                &self
                    .session
                    .request("thread/resume", &serde_json::json!({"threadId": thread_id}))?,
            )
            .map_err(|_| CoreError::InvalidJson)?;
            if exclude_turns {
                result
                    .get_mut("thread")
                    .and_then(serde_json::Value::as_object_mut)
                    .ok_or(CoreError::InvalidJson)?
                    .insert("turns".to_owned(), serde_json::Value::Array(Vec::new()));
            }
            let result = serde_json::to_vec(&result).map_err(|_| CoreError::InvalidJson)?;
            return encode_request_result(request_id.as_ref(), result);
        }
        if matches!(
            request.method.as_str(),
            "thread/archive" | "thread/unarchive" | "thread/delete" | "thread/name/set"
        ) {
            let thread_id = request
                .params
                .get("threadId")
                .and_then(serde_json::Value::as_str)
                .filter(|thread_id| !thread_id.is_empty())
                .ok_or(CoreError::InvalidArgument)?
                .to_owned();
            let command = match request.method.as_str() {
                "thread/name/set" => {
                    let name = request
                        .params
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .filter(|name| !name.trim().is_empty())
                        .ok_or(CoreError::InvalidArgument)?;
                    serde_json::json!({
                        "kind": "thread.set-name",
                        "threadId": thread_id,
                        "name": name,
                    })
                }
                "thread/archive" => serde_json::json!({
                    "kind": "thread.archive",
                    "threadId": thread_id,
                }),
                "thread/unarchive" => serde_json::json!({
                    "kind": "thread.unarchive",
                    "threadId": thread_id,
                }),
                "thread/delete" => serde_json::json!({
                    "kind": "thread.delete",
                    "threadId": thread_id,
                }),
                _ => unreachable!(),
            };
            let internal = serde_json::to_vec(&command).map_err(|_| CoreError::InvalidJson)?;
            self.submit(&internal)?;
            let result = if request.method == "thread/unarchive" {
                let read = self
                    .session
                    .request("thread/read", &serde_json::json!({"threadId": thread_id}))?;
                let value: serde_json::Value =
                    serde_json::from_slice(&read).map_err(|_| CoreError::InvalidJson)?;
                serde_json::to_vec(&serde_json::json!({
                    "thread": value.get("thread").cloned()
                        .ok_or(CoreError::InvalidJson)?,
                }))
                .map_err(|_| CoreError::InvalidJson)?
            } else {
                b"{}".to_vec()
            };
            return encode_request_result(request_id.as_ref(), result);
        }
        let result = self.session.request(&request.method, &request.params)?;
        encode_request_result(request_id.as_ref(), result)
    }

    pub fn submit(&mut self, input: &[u8]) -> Result<(), CoreError> {
        let command: CoreCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        if command.kind == "storage.open" {
            return self.open_storage(input);
        }
        if command.kind == "storage.restore" {
            return self.restore_storage(input);
        }
        if command.kind == "storage.confirm" {
            let storage = self.storage.as_mut().ok_or(CoreError::InvalidArgument)?;
            return storage.confirm();
        }
        if command.kind == "remote_control.enrollment.upsert" {
            let command: EnrollmentUpsertCommand =
                serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
            let key = enrollment_key(
                command.websocket_url,
                command.account_id,
                command.app_server_client_name,
            )?;
            require_enrollment_value(&command.server_id)?;
            require_enrollment_value(&command.environment_id)?;
            require_enrollment_value(&command.server_name)?;
            let enrollment = storage::EnrollmentUpsert {
                key,
                server_id: command.server_id,
                environment_id: command.environment_id,
                server_name: command.server_name,
                updated_at: command.updated_at,
                remote_control_enabled: command.remote_control_enabled,
            };
            let storage = self.storage.as_mut().ok_or(CoreError::InvalidArgument)?;
            return storage.upsert_enrollment(&enrollment);
        }
        if command.kind == "remote_control.enrollment.set_enabled" {
            let command: EnrollmentSetEnabledCommand =
                serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
            let key = enrollment_key(
                command.websocket_url,
                command.account_id,
                command.app_server_client_name,
            )?;
            let storage = self.storage.as_mut().ok_or(CoreError::InvalidArgument)?;
            storage
                .set_enrollment_enabled(&key, command.enabled, command.updated_at)
                .map(|_| ())?;
            return Ok(());
        }
        if command.kind == "remote_control.enrollment.delete" {
            let command: EnrollmentKeyInput =
                serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
            let key = enrollment_key(
                command.websocket_url,
                command.account_id,
                command.app_server_client_name,
            )?;
            let storage = self.storage.as_mut().ok_or(CoreError::InvalidArgument)?;
            storage.delete_enrollment(&key).map(|_| ())?;
            return Ok(());
        }
        if command.kind == "model.catalog.configure" {
            return self.model_catalog.configure(input);
        }
        if command.kind == "model.catalog.clear" {
            self.model_catalog.clear();
            return Ok(());
        }

        let mut candidate_session = self.session.clone();
        let events = if command.kind == "ping" {
            vec![encode_pong(
                self.next_sequence,
                command
                    .request_id
                    .as_deref()
                    .filter(|value| !value.is_empty())
                    .ok_or(CoreError::InvalidArgument)?,
            )?]
        } else {
            candidate_session.submit(&command.kind, input, self.next_sequence)?
        };
        if let Some(storage) = &mut self.storage {
            storage.append(self.next_sequence, input, &events)?;
        }
        self.session = candidate_session;
        self.next_sequence += events.len() as u64;
        self.events.extend(events);
        if let Some(notification) = self.official_thread_status_notification(&command.kind, input) {
            self.events.push_back(notification);
        }
        Ok(())
    }

    fn official_thread_status_notification(&self, kind: &str, input: &[u8]) -> Option<Vec<u8>> {
        let (thread_id, status) = match kind {
            "turn.stable-start" | "thread.compact-start" | "thread.queue.start" => {
                let value: serde_json::Value = serde_json::from_slice(input).ok()?;
                let thread_id = value.get("threadId")?.as_str()?.to_owned();
                (
                    thread_id,
                    serde_json::json!({"type": "active", "activeFlags": []}),
                )
            }
            "turn.complete" | "turn.fail" | "turn.cancel" => {
                let value: serde_json::Value = serde_json::from_slice(input).ok()?;
                let turn_id = value.get("turnId")?.as_str()?;
                let thread_id = self.session.stable_turn_thread_id(turn_id)?.to_owned();
                (thread_id, serde_json::json!({"type": "idle"}))
            }
            "turn.compact-history.commit" => {
                let value: serde_json::Value = serde_json::from_slice(input).ok()?;
                let thread_id = value.get("threadId")?.as_str()?.to_owned();
                (thread_id, serde_json::json!({"type": "idle"}))
            }
            "turn.raw-history.commit" => {
                let value: serde_json::Value = serde_json::from_slice(input).ok()?;
                let completion = value.get("completion")?.as_object()?;
                if completion
                    .get("endTurn")
                    .and_then(serde_json::Value::as_bool)
                    != Some(true)
                {
                    return None;
                }
                let thread_id = value.get("threadId")?.as_str()?.to_owned();
                (thread_id, serde_json::json!({"type": "idle"}))
            }
            _ => return None,
        };
        serde_json::to_vec(&serde_json::json!({
            "method": "thread/status/changed",
            "params": {
                "threadId": thread_id,
                "status": status,
            },
        }))
        .ok()
    }

    fn open_storage(&mut self, input: &[u8]) -> Result<(), CoreError> {
        if self.storage.is_some() || self.next_sequence != 1 || !self.events.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        let command: StorageOpenCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        if command.database_path.is_empty() || command.snapshot_directory.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        let (storage, batches) = storage::Storage::open(
            std::path::Path::new(&command.database_path),
            std::path::Path::new(&command.snapshot_directory),
        )?;
        self.activate_storage(storage, batches)
    }

    fn restore_storage(&mut self, input: &[u8]) -> Result<(), CoreError> {
        if self.storage.is_some() || self.next_sequence != 1 || !self.events.is_empty() {
            return Err(CoreError::InvalidArgument);
        }
        let command: StorageRestoreCommand =
            serde_json::from_slice(input).map_err(|_| CoreError::InvalidJson)?;
        let (storage, batches) = storage::Storage::restore(
            std::path::Path::new(&command.database_path),
            std::path::Path::new(&command.snapshot_directory),
            &command.snapshot_name,
        )?;
        self.activate_storage(storage, batches)
    }

    fn activate_storage(
        &mut self,
        storage: storage::Storage,
        batches: Vec<storage::StoredBatch>,
    ) -> Result<(), CoreError> {
        let mut candidate_session = session::SessionIndex::default();
        let mut next_sequence = 1;
        let mut replay = VecDeque::new();
        for batch in batches {
            if batch.first_sequence != next_sequence {
                return Err(CoreError::Storage);
            }
            let command: CoreCommand =
                serde_json::from_slice(&batch.command).map_err(|_| CoreError::Storage)?;
            let generated = if command.kind == "ping" {
                vec![
                    encode_pong(
                        next_sequence,
                        command
                            .request_id
                            .as_deref()
                            .filter(|value| !value.is_empty())
                            .ok_or(CoreError::Storage)?,
                    )
                    .map_err(|_| CoreError::Storage)?,
                ]
            } else {
                candidate_session
                    .submit(&command.kind, &batch.command, next_sequence)
                    .map_err(|_| CoreError::Storage)?
            };
            if generated != batch.events {
                return Err(CoreError::Storage);
            }
            next_sequence += generated.len() as u64;
            replay.extend(generated);
        }
        self.session = candidate_session;
        self.next_sequence = next_sequence;
        self.events = replay;
        self.storage = Some(storage);
        Ok(())
    }

    pub fn next_event(&mut self) -> Option<Vec<u8>> {
        self.events.pop_front()
    }

    pub fn execute_official_response(&mut self, input: &[u8]) -> Result<(), CoreError> {
        let mut events = Vec::new();
        let result = self.stream_official_response(input, |event| {
            if !event.is_empty() {
                events.push(event);
            }
            true
        });
        self.events.extend(events);
        result
    }

    pub fn stream_official_response(
        &mut self,
        input: &[u8],
        mut emit: impl FnMut(Vec<u8>) -> bool,
    ) -> Result<(), CoreError> {
        let request = official_provider::decode_request(input)?;
        let mut emitted_count = 0;
        let result = official_provider::execute_stream(request, self.next_sequence, |event| {
            let is_event = !event.is_empty();
            let should_continue = emit(event);
            if !should_continue {
                return false;
            }
            if is_event {
                emitted_count += 1;
            }
            true
        });
        self.next_sequence += emitted_count;
        result
    }
}

fn enrollment_key(
    websocket_url: String,
    account_id: String,
    app_server_client_name: Option<String>,
) -> Result<storage::EnrollmentKey, CoreError> {
    require_enrollment_value(&websocket_url)?;
    require_enrollment_value(&account_id)?;
    Ok(storage::EnrollmentKey {
        websocket_url,
        account_id,
        app_server_client_name: app_server_client_name.unwrap_or_default(),
    })
}

fn require_enrollment_value(value: &str) -> Result<(), CoreError> {
    if value.trim().is_empty() {
        return Err(CoreError::InvalidArgument);
    }
    Ok(())
}

fn encode_request_result(
    request_id: Option<&CoreRequestId>,
    result: Vec<u8>,
) -> Result<Vec<u8>, CoreError> {
    let Some(request_id) = request_id else {
        return Ok(result);
    };
    let result: serde_json::Value =
        serde_json::from_slice(&result).map_err(|_| CoreError::InvalidJson)?;
    serde_json::to_vec(&serde_json::json!({
        "id": request_id,
        "result": result,
    }))
    .map_err(|_| CoreError::InvalidJson)
}

fn encode_pong(sequence: u64, request_id: &str) -> Result<Vec<u8>, CoreError> {
    serde_json::to_vec(&CoreEvent {
        sequence,
        kind: "pong",
        request_id,
    })
    .map_err(|_| CoreError::InvalidJson)
}

#[repr(C)]
pub struct CodexCoreHandle {
    core: CodexCore,
}

#[repr(C)]
pub struct CodexCoreNativeOfficialStream {
    stream: official_provider::NativeOfficialStream,
}

#[derive(Deserialize)]
struct CodexCoreNativeResponseHeader {
    name: String,
    value: String,
}

#[repr(C)]
#[derive(Debug, Default)]
pub struct CodexCoreBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub capacity: usize,
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexCoreStatus {
    Ok = 0,
    InvalidArgument = 1,
    InvalidJson = 2,
    UnsupportedCommand = 3,
    NoEvent = 4,
    Storage = 5,
    Network = 6,
    Cancelled = 7,
    Panic = 255,
}

impl From<CoreError> for CodexCoreStatus {
    fn from(value: CoreError) -> Self {
        match value {
            CoreError::InvalidArgument => Self::InvalidArgument,
            CoreError::InvalidJson => Self::InvalidJson,
            CoreError::UnsupportedCommand => Self::UnsupportedCommand,
            CoreError::Storage => Self::Storage,
            CoreError::Network => Self::Network,
            CoreError::Cancelled => Self::Cancelled,
        }
    }
}

fn ffi_status(operation: impl FnOnce() -> CodexCoreStatus) -> CodexCoreStatus {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(CodexCoreStatus::Panic)
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_core_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn codex_core_create() -> *mut CodexCoreHandle {
    catch_unwind(|| {
        Box::into_raw(Box::new(CodexCoreHandle {
            core: CodexCore::default(),
        }))
    })
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_destroy(handle: *mut CodexCoreHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(handle));
    }));
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_submit_json(
    handle: *mut CodexCoreHandle,
    bytes: *const u8,
    length: usize,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || (bytes.is_null() && length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let core = unsafe { &mut (*handle).core };
        core.submit(input)
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_request_json(
    handle: *mut CodexCoreHandle,
    bytes: *const u8,
    length: usize,
    output: *mut CodexCoreBuffer,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || output.is_null() || (bytes.is_null() && length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        unsafe { output.write(CodexCoreBuffer::default()) };
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let core = unsafe { &mut (*handle).core };
        match core.request(input) {
            Ok(mut response) => {
                let buffer = CodexCoreBuffer {
                    ptr: response.as_mut_ptr(),
                    len: response.len(),
                    capacity: response.capacity(),
                };
                std::mem::forget(response);
                unsafe { output.write(buffer) };
                CodexCoreStatus::Ok
            }
            Err(error) => error.into(),
        }
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_execute_official_response_json(
    handle: *mut CodexCoreHandle,
    bytes: *const u8,
    length: usize,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || (bytes.is_null() && length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let core = unsafe { &mut (*handle).core };
        core.execute_official_response(input)
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

pub type CodexCoreEventCallback =
    Option<extern "C" fn(bytes: *const u8, length: usize, context: *mut c_void) -> i32>;

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_stream_official_response_json(
    handle: *mut CodexCoreHandle,
    bytes: *const u8,
    length: usize,
    callback: CodexCoreEventCallback,
    context: *mut c_void,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || callback.is_none() || (bytes.is_null() && length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let callback = callback.expect("callback was validated");
        let core = unsafe { &mut (*handle).core };
        core.stream_official_response(input, |event| {
            callback(event.as_ptr(), event.len(), context) != 0
        })
        .map(|()| CodexCoreStatus::Ok)
        .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_create(
    handle: *mut CodexCoreHandle,
    bytes: *const u8,
    length: usize,
    callback: CodexCoreEventCallback,
    context: *mut c_void,
    prepared_request_output: *mut CodexCoreBuffer,
    stream_output: *mut *mut CodexCoreNativeOfficialStream,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null()
            || callback.is_none()
            || prepared_request_output.is_null()
            || stream_output.is_null()
            || (bytes.is_null() && length != 0)
        {
            return CodexCoreStatus::InvalidArgument;
        }
        unsafe {
            prepared_request_output.write(CodexCoreBuffer::default());
            stream_output.write(ptr::null_mut());
        }
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let request = match official_provider::decode_request(input) {
            Ok(request) => request,
            Err(error) => return error.into(),
        };
        let callback = callback.expect("callback was validated");
        let context_address = context as usize;
        let first_sequence = unsafe { (*handle).core.next_sequence };
        let (prepared, mut stream) =
            match official_provider::start_native_stream(request, first_sequence, move |event| {
                callback(event.as_ptr(), event.len(), context_address as *mut c_void) != 0
            }) {
                Ok(value) => value,
                Err(error) => return error.into(),
            };
        let mut encoded = match serde_json::to_vec(&prepared) {
            Ok(encoded) => encoded,
            Err(_) => {
                stream.cancel();
                let _ = stream.finish();
                return CodexCoreStatus::InvalidJson;
            }
        };
        let buffer = CodexCoreBuffer {
            ptr: encoded.as_mut_ptr(),
            len: encoded.len(),
            capacity: encoded.capacity(),
        };
        std::mem::forget(encoded);
        let stream = Box::into_raw(Box::new(CodexCoreNativeOfficialStream { stream }));
        unsafe {
            prepared_request_output.write(buffer);
            stream_output.write(stream);
        }
        CodexCoreStatus::Ok
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_begin_response_json(
    stream: *mut CodexCoreNativeOfficialStream,
    status: u16,
    headers_json: *const u8,
    headers_json_length: usize,
) -> CodexCoreStatus {
    ffi_status(|| {
        if stream.is_null() || (headers_json.is_null() && headers_json_length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        let input = if headers_json_length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(headers_json, headers_json_length) }
        };
        let headers: Vec<CodexCoreNativeResponseHeader> = match serde_json::from_slice(input) {
            Ok(headers) => headers,
            Err(_) => return CodexCoreStatus::InvalidJson,
        };
        unsafe { &mut (*stream).stream }
            .begin_response(
                status,
                headers
                    .into_iter()
                    .map(|header| (header.name, header.value))
                    .collect(),
            )
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_push_body(
    stream: *mut CodexCoreNativeOfficialStream,
    bytes: *const u8,
    length: usize,
) -> CodexCoreStatus {
    ffi_status(|| {
        if stream.is_null() || (bytes.is_null() && length != 0) {
            return CodexCoreStatus::InvalidArgument;
        }
        let input = if length == 0 {
            &[]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        unsafe { &mut (*stream).stream }
            .push_body(input)
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_end_body(
    stream: *mut CodexCoreNativeOfficialStream,
) -> CodexCoreStatus {
    ffi_status(|| {
        if stream.is_null() {
            return CodexCoreStatus::InvalidArgument;
        }
        unsafe { &mut (*stream).stream }
            .end_body()
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_cancel(
    stream: *mut CodexCoreNativeOfficialStream,
) -> CodexCoreStatus {
    ffi_status(|| {
        if stream.is_null() {
            return CodexCoreStatus::InvalidArgument;
        }
        unsafe { &mut (*stream).stream }.cancel();
        CodexCoreStatus::Ok
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_native_official_stream_finish(
    handle: *mut CodexCoreHandle,
    stream: *mut CodexCoreNativeOfficialStream,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || stream.is_null() {
            return CodexCoreStatus::InvalidArgument;
        }
        let mut stream = unsafe { Box::from_raw(stream) };
        let completion = stream.stream.finish();
        unsafe {
            (*handle).core.next_sequence = (*handle)
                .core
                .next_sequence
                .saturating_add(completion.emitted_count);
        }
        completion
            .result
            .map(|()| CodexCoreStatus::Ok)
            .unwrap_or_else(Into::into)
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_next_event_json(
    handle: *mut CodexCoreHandle,
    output: *mut CodexCoreBuffer,
) -> CodexCoreStatus {
    ffi_status(|| {
        if handle.is_null() || output.is_null() {
            return CodexCoreStatus::InvalidArgument;
        }
        unsafe { output.write(CodexCoreBuffer::default()) };
        let core = unsafe { &mut (*handle).core };
        let Some(mut event) = core.next_event() else {
            return CodexCoreStatus::NoEvent;
        };
        let buffer = CodexCoreBuffer {
            ptr: event.as_mut_ptr(),
            len: event.len(),
            capacity: event.capacity(),
        };
        std::mem::forget(event);
        unsafe { output.write(buffer) };
        CodexCoreStatus::Ok
    })
}

#[unsafe(no_mangle)]
#[allow(clippy::not_unsafe_ptr_arg_deref)]
pub extern "C" fn codex_core_buffer_free(buffer: *mut CodexCoreBuffer) {
    if buffer.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let value = &mut *buffer;
        if !value.ptr.is_null() && value.capacity > 0 && value.len <= value.capacity {
            drop(Vec::from_raw_parts(value.ptr, value.len, value.capacity));
        }
        *value = CodexCoreBuffer::default();
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;

    extern "C" fn collect_native_provider_event(
        bytes: *const u8,
        length: usize,
        context: *mut c_void,
    ) -> i32 {
        if context.is_null() || (bytes.is_null() && length != 0) {
            return 0;
        }
        let event = if length == 0 {
            Vec::new()
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }.to_vec()
        };
        unsafe { &mut *(context.cast::<Vec<Vec<u8>>>()) }.push(event);
        1
    }

    #[test]
    fn ping_emits_monotonic_pong_events() {
        let mut core = CodexCore::default();
        core.submit(br#"{"kind":"ping","requestId":"one"}"#)
            .unwrap();
        core.submit(br#"{"kind":"ping","requestId":"two"}"#)
            .unwrap();
        assert_eq!(
            core.next_event().unwrap(),
            br#"{"sequence":1,"kind":"pong","requestId":"one"}"#
        );
        assert_eq!(
            core.next_event().unwrap(),
            br#"{"sequence":2,"kind":"pong","requestId":"two"}"#
        );
    }

    #[test]
    fn malformed_and_unknown_commands_do_not_advance_sequence() {
        let mut core = CodexCore::default();
        assert_eq!(core.submit(b"{"), Err(CoreError::InvalidJson));
        assert_eq!(
            core.submit(br#"{"kind":"other","requestId":"x"}"#),
            Err(CoreError::UnsupportedCommand)
        );
        core.submit(br#"{"kind":"ping","requestId":"ok"}"#).unwrap();
        assert!(core.next_event().unwrap().starts_with(br#"{"sequence":1,"#));
    }

    #[test]
    fn deleting_a_thread_emits_lifecycle_event_and_rejects_reuse() {
        let mut core = CodexCore::default();
        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Project","rootBookmarkId":null}}"#,
        )
        .unwrap();
        core.submit(
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"}}"#,
        )
        .unwrap();
        core.submit(
            br#"{"kind":"thread.delete","threadId":"00000000-0000-0000-0000-000000000002"}"#,
        )
        .unwrap();
        assert_eq!(
            core.events.back().unwrap(),
            br#"{"sequence":3,"kind":"threadDeleted","threadId":"00000000-0000-0000-0000-000000000002"}"#
        );
        assert_eq!(
            core.submit(
                br#"{"kind":"thread.delete","threadId":"00000000-0000-0000-0000-000000000002"}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn thread_queue_add_list_and_persist_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();
        seed_thread_directory(&mut core);
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"add","method":"thread/queue/add","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"queued"}],"clientUserMessageId":"client-1"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response["result"]["queuedSubmission"]["input"][0]["text"],
            "queued"
        );
        let list: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"list","method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(list["result"]["data"].as_array().unwrap().len(), 1);
        let mut reopened = CodexCore::default();
        reopened
            .submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();
        let replayed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(br#"{"id":"replay-list","method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(replayed["result"]["data"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn thread_queue_update_delete_reorder_and_cursor_are_atomic() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let add = |core: &mut CodexCore, client: &str, text: &str| -> String {
            let request = serde_json::json!({
                "id": client,
                "method": "thread/queue/add",
                "params": {"threadId": "00000000-0000-0000-0000-000000000002", "input": [{"type":"text","text":text}], "clientUserMessageId": client}
            });
            let response: serde_json::Value = serde_json::from_slice(
                &core
                    .request(&serde_json::to_vec(&request).unwrap())
                    .unwrap(),
            )
            .unwrap();
            response["result"]["queuedSubmission"]["id"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let first = add(&mut core, "client-1", "one");
        let second = add(&mut core, "client-2", "two");
        let update = serde_json::json!({"id":"update","method":"thread/queue/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","queuedSubmissionId":first,"input":[{"type":"text","text":"ONE"}]}});
        core.request(&serde_json::to_vec(&update).unwrap()).unwrap();
        let reorder = serde_json::json!({"id":"reorder","method":"thread/queue/reorder","params":{"threadId":"00000000-0000-0000-0000-000000000002","queuedSubmissionIds":[second,first]}});
        core.request(&serde_json::to_vec(&reorder).unwrap())
            .unwrap();
        let page: serde_json::Value = serde_json::from_slice(&core.request(br#"{"id":"page","method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002","limit":1}}"#).unwrap()).unwrap();
        assert_eq!(page["result"]["data"][0]["clientUserMessageId"], "client-2");
        let cursor = page["result"]["nextCursor"].as_str().unwrap();
        let next: serde_json::Value = serde_json::from_slice(&core.request(serde_json::to_vec(&serde_json::json!({"id":"next","method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002","cursor":cursor}})).unwrap().as_slice()).unwrap()).unwrap();
        assert_eq!(next["result"]["data"][0]["input"][0]["text"], "ONE");
        let bad = serde_json::json!({"method":"thread/queue/reorder","params":{"threadId":"00000000-0000-0000-0000-000000000002","queuedSubmissionIds":[first,first]}});
        assert_eq!(
            core.request(&serde_json::to_vec(&bad).unwrap()),
            Err(CoreError::InvalidArgument)
        );
        let delete = serde_json::json!({"id":"delete","method":"thread/queue/delete","params":{"threadId":"00000000-0000-0000-0000-000000000002","queuedSubmissionId":second}});
        let deleted: serde_json::Value =
            serde_json::from_slice(&core.request(&serde_json::to_vec(&delete).unwrap()).unwrap())
                .unwrap();
        assert_eq!(deleted["result"]["deleted"], true);
    }

    #[test]
    fn thread_queue_start_requires_a_loaded_idle_thread_and_preserves_rejections() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        while core.next_event().is_some() {}

        let added: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"add","method":"thread/queue/add","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"queued"}],"clientUserMessageId":"client-queued"}}"#)
                .unwrap(),
        )
        .unwrap();
        let queued_id = added["result"]["queuedSubmission"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        while core.next_event().is_some() {}

        assert_eq!(
            core.request(
                serde_json::to_vec(&serde_json::json!({
                    "method": "thread/queue/start",
                    "params": {
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "queuedSubmissionId": queued_id,
                    },
                }))
                .unwrap()
                .as_slice(),
            ),
            Err(CoreError::InvalidArgument)
        );
        let still_queued: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(still_queued["data"].as_array().unwrap().len(), 1);

        core.session
            .subscribe_thread("00000000-0000-0000-0000-000000000002")
            .unwrap();
        while core.next_event().is_some() {}

        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_vec(&serde_json::json!({
                        "id": "start",
                        "method": "thread/queue/start",
                        "params": {
                            "threadId": "00000000-0000-0000-0000-000000000002",
                            "queuedSubmissionId": queued_id,
                        },
                    }))
                    .unwrap()
                    .as_slice(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(started["id"], "start");
        assert_eq!(started["result"]["turn"]["status"], "inProgress");
        assert_eq!(started["result"]["turn"]["items"], serde_json::json!([]));
        assert_eq!(started["result"]["turn"]["itemsView"], "notLoaded");
        let turn_id = started["result"]["turn"]["id"].as_str().unwrap().to_owned();

        let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(events[0]["kind"], "stableTurnStarted");
        assert_eq!(events[0]["turnId"], turn_id);
        assert_eq!(events[0]["params"]["input"][0]["text"], "queued");
        assert_eq!(events[0]["params"]["clientUserMessageId"], "client-queued");
        assert_eq!(events[1]["kind"], "threadQueueChanged");
        assert_eq!(events[1]["queuedSubmissions"], serde_json::json!([]));
        assert_eq!(events[2]["method"], "thread/status/changed");
        assert_eq!(events[2]["params"]["status"]["type"], "active");

        let second: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/queue/add","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"stay queued"}],"clientUserMessageId":"client-stay"}}"#)
                .unwrap(),
        )
        .unwrap();
        let second_id = second["queuedSubmission"]["id"].as_str().unwrap();
        while core.next_event().is_some() {}
        assert_eq!(
            core.request(
                serde_json::to_vec(&serde_json::json!({
                    "method": "thread/queue/start",
                    "params": {
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "queuedSubmissionId": second_id,
                    },
                }))
                .unwrap()
                .as_slice(),
            ),
            Err(CoreError::InvalidArgument)
        );
        let preserved: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/queue/list","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(preserved["data"].as_array().unwrap().len(), 1);
        assert_eq!(preserved["data"][0]["id"], second_id);
    }

    #[test]
    fn thread_queue_start_without_id_consumes_the_head_only() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.session
            .subscribe_thread("00000000-0000-0000-0000-000000000002")
            .unwrap();
        while core.next_event().is_some() {}

        for (client, text) in [("client-first", "first"), ("client-second", "second")] {
            core.request(
                serde_json::to_vec(&serde_json::json!({
                    "method": "thread/queue/add",
                    "params": {
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "input": [{"type": "text", "text": text}],
                        "clientUserMessageId": client,
                    },
                }))
                .unwrap()
                .as_slice(),
            )
            .unwrap();
        }
        while core.next_event().is_some() {}

        core.request(
            br#"{"method":"thread/queue/start","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
        )
        .unwrap();
        let started =
            serde_json::from_slice::<serde_json::Value>(&core.next_event().unwrap()).unwrap();
        assert_eq!(started["params"]["clientUserMessageId"], "client-first");
        let changed =
            serde_json::from_slice::<serde_json::Value>(&core.next_event().unwrap()).unwrap();
        assert_eq!(changed["kind"], "threadQueueChanged");
        assert_eq!(changed["queuedSubmissions"].as_array().unwrap().len(), 1);
        assert_eq!(
            changed["queuedSubmissions"][0]["clientUserMessageId"],
            "client-second"
        );
    }

    #[test]
    fn workspace_update_replaces_metadata_and_emits_upsert() {
        let mut core = CodexCore::default();
        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Project","rootBookmarkId":null}}"#,
        )
        .unwrap();
        assert!(core.next_event().is_some());

        core.submit(
            br#"{"kind":"workspace.update","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Renamed Project","rootBookmarkId":"UPDATED_BOOKMARK_SAMPLE"}}"#,
        )
        .unwrap();

        assert_eq!(
            core.next_event().unwrap(),
            br#"{"sequence":2,"kind":"workspaceUpserted","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Renamed Project","rootBookmarkId":"UPDATED_BOOKMARK_SAMPLE"}}"#
        );
        assert!(core.next_event().is_none());
    }

    #[test]
    fn workspace_update_rejects_missing_id_and_blank_name_atomically() {
        let mut core = CodexCore::default();
        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Project","rootBookmarkId":null}}"#,
        )
        .unwrap();
        assert!(core.next_event().is_some());
        let sequence = core.next_sequence;

        for command in [
            br#"{"kind":"workspace.update","workspace":{"id":"00000000-0000-0000-0000-999999999999","displayName":"Missing","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"workspace.update","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"  ","rootBookmarkId":null}}"#.as_slice(),
        ] {
            assert_eq!(core.submit(command), Err(CoreError::InvalidArgument));
            assert_eq!(core.next_sequence, sequence);
            assert!(core.next_event().is_none());
        }

        core.submit(
            br#"{"kind":"workspace.update","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Valid","rootBookmarkId":null}}"#,
        )
        .unwrap();
        assert!(
            core.next_event()
                .unwrap()
                .starts_with(br#"{"sequence":2,"kind":"workspaceUpserted""#)
        );
    }

    #[test]
    fn workspace_remove_is_atomic_while_referenced_then_removes_and_emits() {
        let mut core = CodexCore::default();
        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Project","rootBookmarkId":null}}"#,
        )
        .unwrap();
        core.submit(
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"}}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        let sequence = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"workspace.remove","workspaceId":"00000000-0000-0000-0000-000000000001"}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence);
        assert!(core.next_event().is_none());

        core.submit(
            br#"{"kind":"thread.delete","threadId":"00000000-0000-0000-0000-000000000002"}"#,
        )
        .unwrap();
        assert!(core.next_event().is_some());
        core.submit(
            br#"{"kind":"workspace.remove","workspaceId":"00000000-0000-0000-0000-000000000001"}"#,
        )
        .unwrap();
        assert_eq!(
            core.next_event().unwrap(),
            br#"{"sequence":4,"kind":"workspaceRemoved","workspaceId":"00000000-0000-0000-0000-000000000001"}"#
        );

        assert_eq!(
            core.submit(
                br#"{"kind":"workspace.remove","workspaceId":"00000000-0000-0000-0000-000000000001"}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            core.submit(
                br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000003","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Orphan"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert!(core.next_event().is_none());

        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Reopened","rootBookmarkId":null}}"#,
        )
        .unwrap();
        assert!(
            core.next_event()
                .unwrap()
                .starts_with(br#"{"sequence":5,"kind":"workspaceUpserted""#)
        );
    }

    #[test]
    fn c_abi_transfers_and_frees_exact_event_bytes() {
        let handle = codex_core_create();
        assert!(!handle.is_null());
        let command = br#"{"kind":"ping","requestId":"ffi"}"#;
        assert_eq!(
            codex_core_submit_json(handle, command.as_ptr(), command.len()),
            CodexCoreStatus::Ok
        );
        let mut output = CodexCoreBuffer::default();
        assert_eq!(
            codex_core_next_event_json(handle, &mut output),
            CodexCoreStatus::Ok
        );
        let event = unsafe { slice::from_raw_parts(output.ptr, output.len) };
        assert_eq!(event, br#"{"sequence":1,"kind":"pong","requestId":"ffi"}"#);
        codex_core_buffer_free(&mut output);
        assert!(output.ptr.is_null());
        assert_eq!(output.len, 0);
        assert_eq!(output.capacity, 0);
        assert_eq!(
            codex_core_next_event_json(handle, &mut output),
            CodexCoreStatus::NoEvent
        );
        codex_core_destroy(handle);
    }

    #[test]
    fn c_abi_returns_exact_thread_request_bytes() {
        let handle = codex_core_create();
        assert!(!handle.is_null());
        seed_thread_directory(unsafe { &mut (*handle).core });

        let request = br#"{"id":"ffi-list","method":"thread/list","params":{"limit":1}}"#;
        let mut output = CodexCoreBuffer::default();
        assert_eq!(
            codex_core_request_json(handle, request.as_ptr(), request.len(), &mut output),
            CodexCoreStatus::Ok
        );
        let response = unsafe { slice::from_raw_parts(output.ptr, output.len) };
        let decoded: serde_json::Value = serde_json::from_slice(response).unwrap();
        assert_eq!(decoded["id"], "ffi-list");
        assert_eq!(decoded["result"]["data"].as_array().unwrap().len(), 1);
        codex_core_buffer_free(&mut output);
        assert!(output.ptr.is_null());
        assert_eq!(
            codex_core_request_json(handle, request.as_ptr(), request.len(), ptr::null_mut()),
            CodexCoreStatus::InvalidArgument
        );
        codex_core_destroy(handle);
    }

    #[test]
    fn c_abi_native_provider_stream_bridges_request_response_and_sequence() {
        let handle = codex_core_create();
        assert!(!handle.is_null());
        let request = br#"{
            "requestId":"native-ffi",
            "accessToken":"secret-in-memory-only",
            "accountId":"account-1",
            "proxyUrl":"http://127.0.0.1:1082",
            "model":"gpt-test",
            "reasoningEffort":"high",
            "instructions":"Be precise.",
            "input":[{"type":"text","text":"Hello","textElements":[]}]
        }"#;
        let mut prepared = CodexCoreBuffer::default();
        let mut stream: *mut CodexCoreNativeOfficialStream = ptr::null_mut();
        let mut events: Vec<Vec<u8>> = Vec::new();
        assert_eq!(
            codex_core_native_official_stream_create(
                handle,
                request.as_ptr(),
                request.len(),
                Some(collect_native_provider_event),
                (&mut events as *mut Vec<Vec<u8>>).cast(),
                &mut prepared,
                &mut stream,
            ),
            CodexCoreStatus::Ok
        );
        assert!(!stream.is_null());
        let prepared_json: serde_json::Value =
            serde_json::from_slice(unsafe { slice::from_raw_parts(prepared.ptr, prepared.len) })
                .unwrap();
        assert_eq!(
            prepared_json["url"],
            "https://chatgpt.com/backend-api/codex/responses"
        );
        assert_eq!(prepared_json["proxyUrl"], "http://127.0.0.1:1082");
        assert!(
            prepared_json["headers"]
                .as_array()
                .unwrap()
                .iter()
                .any(|header| {
                    header["name"] == "authorization"
                        && header["value"] == "Bearer secret-in-memory-only"
                })
        );
        let body = base64::engine::general_purpose::STANDARD
            .decode(prepared_json["bodyBase64"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap()["model"],
            "gpt-test"
        );
        codex_core_buffer_free(&mut prepared);

        assert_eq!(
            codex_core_native_official_stream_begin_response_json(stream, 200, b"[]".as_ptr(), 2,),
            CodexCoreStatus::Ok
        );
        let sse = br#"data: {"type":"response.created","response":{}}

data: {"type":"response.output_text.delta","delta":"hello"}

data: {"type":"response.completed","response":{"id":"response-native-ffi","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2},"end_turn":true}}

"#;
        assert_eq!(
            codex_core_native_official_stream_push_body(stream, sse.as_ptr(), sse.len()),
            CodexCoreStatus::Ok
        );
        assert_eq!(
            codex_core_native_official_stream_end_body(stream),
            CodexCoreStatus::Ok
        );
        assert_eq!(
            codex_core_native_official_stream_finish(handle, stream),
            CodexCoreStatus::Ok
        );
        assert!(events.iter().any(|event| {
            serde_json::from_slice::<serde_json::Value>(event).is_ok_and(|event| {
                event["kind"] == "assistantTextDelta" && event["delta"] == "hello"
            })
        }));
        let expected_next_sequence =
            1 + events.iter().filter(|event| !event.is_empty()).count() as u64;
        assert_eq!(
            unsafe { (*handle).core.next_sequence },
            expected_next_sequence
        );
        codex_core_destroy(handle);
    }

    #[test]
    fn session_flow_emits_six_ordered_domain_events() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 4] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000003","assistantItem":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Project inspection complete"}}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }

        let expected: [&[u8]; 6] = [
            br#"{"sequence":1,"kind":"workspaceUpserted","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"sequence":2,"kind":"threadUpserted","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"sequence":3,"kind":"turnStarted","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"}}"#,
            br#"{"sequence":4,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"sequence":5,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Project inspection complete"}}"#,
            br#"{"sequence":6,"kind":"turnStatusChanged","turnId":"00000000-0000-0000-0000-000000000003","status":"completed"}"#,
        ];
        for event in expected {
            assert_eq!(core.next_event().unwrap(), event);
        }
        assert!(core.next_event().is_none());
    }

    #[test]
    fn failed_turn_emits_error_item_and_terminal_status() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 4] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"kind":"turn.fail","turnId":"00000000-0000-0000-0000-000000000003","errorItem":{"id":"00000000-0000-0000-0000-000000000006","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"error","text":"Codex request failed."}}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(events.len(), 6);
        assert_eq!(
            events[4],
            br#"{"sequence":5,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000006","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"error","text":"Codex request failed."}}"#
        );
        assert_eq!(
            events[5],
            br#"{"sequence":6,"kind":"turnStatusChanged","turnId":"00000000-0000-0000-0000-000000000003","status":"failed"}"#
        );
    }

    #[test]
    fn cancelled_turn_emits_terminal_status_without_error_item() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 4] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"kind":"turn.cancel","turnId":"00000000-0000-0000-0000-000000000003"}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(events.len(), 5);
        assert_eq!(
            events[4],
            br#"{"sequence":5,"kind":"turnStatusChanged","turnId":"00000000-0000-0000-0000-000000000003","status":"cancelled"}"#
        );
    }

    #[test]
    fn thread_rename_emits_name_updated_notification() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 3] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"thread.set-name","threadId":"00000000-0000-0000-0000-000000000002","name":"Renamed task"}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(
            events[2],
            br#"{"sequence":3,"kind":"threadNameUpdated","threadId":"00000000-0000-0000-0000-000000000002","name":"Renamed task"}"#
        );
    }

    #[test]
    fn thread_archive_lifecycle_emits_official_notifications() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 4] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"thread.archive","threadId":"00000000-0000-0000-0000-000000000002"}"#,
            br#"{"kind":"thread.unarchive","threadId":"00000000-0000-0000-0000-000000000002"}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(
            events[2],
            br#"{"sequence":3,"kind":"threadArchived","threadId":"00000000-0000-0000-0000-000000000002"}"#
        );
        assert_eq!(
            events[3],
            br#"{"sequence":4,"kind":"threadUnarchived","threadId":"00000000-0000-0000-0000-000000000002"}"#
        );
    }

    #[test]
    fn thread_fork_copies_completed_history_with_remapped_ids() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 5] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000003","assistantItem":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Done"}}"#,
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000006","title":"First task (fork)","lastTurnId":"00000000-0000-0000-0000-000000000003","turnIdMap":{"00000000-0000-0000-0000-000000000003":"00000000-0000-0000-0000-000000000007"},"itemIdMap":{"00000000-0000-0000-0000-000000000004":"00000000-0000-0000-0000-000000000008","00000000-0000-0000-0000-000000000005":"00000000-0000-0000-0000-000000000009"}}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(events.len(), 10);
        assert_eq!(
            events[6],
            br#"{"sequence":7,"kind":"threadUpserted","thread":{"id":"00000000-0000-0000-0000-000000000006","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task (fork)"}}"#
        );
        assert_eq!(
            events[7],
            br#"{"sequence":8,"kind":"turnStarted","turn":{"id":"00000000-0000-0000-0000-000000000007","threadId":"00000000-0000-0000-0000-000000000006","status":"completed"}}"#
        );
        assert!(
            events[8]
                .windows(36)
                .any(|bytes| bytes == b"00000000-0000-0000-0000-000000000008")
        );
        assert!(
            events[9]
                .windows(36)
                .any(|bytes| bytes == b"00000000-0000-0000-0000-000000000009")
        );
    }

    #[test]
    fn thread_fork_rejects_an_in_progress_cutoff_atomically() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect"}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let queued_before = core.events.len();
        assert_eq!(
            core.submit(br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000006","title":"Fork","lastTurnId":"00000000-0000-0000-0000-000000000003","turnIdMap":{"00000000-0000-0000-0000-000000000003":"00000000-0000-0000-0000-000000000007"},"itemIdMap":{"00000000-0000-0000-0000-000000000004":"00000000-0000-0000-0000-000000000008"}}"#),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.events.len(), queued_before);
    }

    #[test]
    fn thread_goal_set_and_clear_emit_persistable_notifications() {
        let mut core = CodexCore::default();
        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
        )
        .unwrap();
        core.submit(
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"}}"#,
        )
        .unwrap();
        core.submit(
            br#"{"kind":"thread.goal.set","threadId":"00000000-0000-0000-0000-000000000002","objective":"Ship the iPad build","status":"active","tokenBudget":12000}"#,
        )
        .unwrap();
        let updated: serde_json::Value =
            serde_json::from_slice(core.events.back().unwrap()).unwrap();
        assert_eq!(updated["kind"], "threadGoalUpdated");
        assert_eq!(updated["goal"]["objective"], "Ship the iPad build");
        assert_eq!(updated["goal"]["status"], "active");
        assert_eq!(updated["goal"]["tokenBudget"], 12000);
        assert_eq!(updated["goal"]["tokensUsed"], 0);
        core.submit(
            br#"{"kind":"thread.goal.clear","threadId":"00000000-0000-0000-0000-000000000002"}"#,
        )
        .unwrap();
        assert_eq!(
            core.events.back().unwrap(),
            br#"{"sequence":4,"kind":"threadGoalCleared","threadId":"00000000-0000-0000-0000-000000000002"}"#
        );
    }

    #[test]
    fn thread_goal_patch_and_archive_round_trip_preserve_goal_state() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"}}"#.as_slice(),
            br#"{"kind":"thread.goal.set","threadId":"00000000-0000-0000-0000-000000000002","objective":"Ship","status":"active","tokenBudget":12000}"#.as_slice(),
            br#"{"kind":"thread.archive","threadId":"00000000-0000-0000-0000-000000000002"}"#.as_slice(),
            br#"{"kind":"thread.unarchive","threadId":"00000000-0000-0000-0000-000000000002"}"#.as_slice(),
            br#"{"kind":"thread.goal.set","threadId":"00000000-0000-0000-0000-000000000002","status":"paused","tokenBudget":null}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let updated: serde_json::Value =
            serde_json::from_slice(core.events.back().unwrap()).unwrap();
        assert_eq!(updated["goal"]["objective"], "Ship");
        assert_eq!(updated["goal"]["status"], "paused");
        assert!(updated["goal"]["tokenBudget"].is_null());
        core.submit(
            br#"{"kind":"thread.goal.clear","threadId":"00000000-0000-0000-0000-000000000002"}"#,
        )
        .unwrap();
    }

    #[test]
    fn thread_settings_update_emits_official_effective_settings() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"},"metadata":{"sessionId":"provider-preservation","preview":"","ephemeral":false,"modelProvider":"custom-provider","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace","model":"gpt-5.4","effort":"high","approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","networkAccess":false,"writableRoots":[],"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let event: serde_json::Value = serde_json::from_slice(core.events.back().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadSettingsUpdated");
        assert_eq!(event["threadSettings"]["cwd"], "/workspace");
        assert_eq!(event["threadSettings"]["model"], "gpt-5.4");
        assert_eq!(event["threadSettings"]["modelProvider"], "custom-provider");
        assert_eq!(event["threadSettings"]["effort"], "high");
        assert_eq!(event["threadSettings"]["approvalPolicy"], "on-request");
        assert_eq!(
            event["threadSettings"]["sandboxPolicy"]["type"],
            "workspaceWrite"
        );
        assert_eq!(
            event["threadSettings"]["sandboxPolicy"]["writableRoots"],
            serde_json::json!([])
        );
        assert_eq!(
            event["threadSettings"]["sandboxPolicy"]["excludeTmpdirEnvVar"],
            false
        );
        assert_eq!(
            event["threadSettings"]["multiAgentMode"],
            "explicitRequestOnly"
        );
    }

    #[test]
    fn thread_settings_update_accepts_the_complete_official_patch_surface() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"},"metadata":{"sessionId":"settings-complete","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace","model":"gpt-5.4","effort":"ultra","approvalPolicy":{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}},"approvalsReviewer":"auto_review","sandboxPolicy":{"type":"externalSandbox","networkAccess":"enabled"},"serviceTier":"priority","summary":"detailed","collaborationMode":{"mode":"plan","settings":{"model":"ignored-in-favor-of-effective-model","reasoning_effort":"low","developer_instructions":"Plan carefully."}},"multiAgentMode":"proactive","personality":"pragmatic"}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let event: serde_json::Value = serde_json::from_slice(core.events.back().unwrap()).unwrap();
        let settings = &event["threadSettings"];
        assert_eq!(settings["approvalPolicy"]["granular"]["rules"], false);
        assert_eq!(settings["approvalsReviewer"], "auto_review");
        assert_eq!(settings["sandboxPolicy"]["type"], "externalSandbox");
        assert_eq!(settings["sandboxPolicy"]["networkAccess"], "enabled");
        assert_eq!(settings["serviceTier"], "priority");
        assert_eq!(settings["summary"], "detailed");
        assert_eq!(settings["modelProvider"], "openai");
        assert_eq!(settings["model"], "ignored-in-favor-of-effective-model");
        assert_eq!(settings["effort"], "low");
        assert_eq!(settings["collaborationMode"]["mode"], "plan");
        assert_eq!(
            settings["collaborationMode"]["settings"]["model"],
            "ignored-in-favor-of-effective-model"
        );
        assert_eq!(
            settings["collaborationMode"]["settings"]["reasoning_effort"],
            "low"
        );
        assert_eq!(
            settings["collaborationMode"]["settings"]["developer_instructions"],
            "Plan carefully."
        );
        assert_eq!(settings["multiAgentMode"], "explicitRequestOnly");
        assert_eq!(settings["personality"], "pragmatic");

        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","permissions":":workspace","serviceTier":null,"summary":null,"personality":null}"#,
        )
        .unwrap();
        let patched: serde_json::Value =
            serde_json::from_slice(core.events.back().unwrap()).unwrap();
        assert_eq!(
            patched["threadSettings"]["activePermissionProfile"]["id"],
            ":workspace"
        );
        assert_eq!(patched["threadSettings"]["serviceTier"], "default");
        assert_eq!(
            patched["threadSettings"]["sandboxPolicy"],
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": [],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            })
        );
        assert_eq!(patched["threadSettings"]["summary"], "detailed");
        assert_eq!(patched["threadSettings"]["personality"], "pragmatic");
    }

    #[test]
    fn thread_settings_update_rpc_echoes_id_and_emits_the_official_notification() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Settings exact ID"},"metadata":{"sessionId":"settings-rpc","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/original","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":73,"method":"thread/settings/update","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","cwd":"/workspace/updated","approvalPolicy":{"granular":{"sandbox_approval":true,"rules":false,"mcp_elicitations":true}},"approvalsReviewer":"auto_review","sandboxPolicy":{"type":"workspaceWrite"},"model":"gpt-5.6","effort":"high","serviceTier":"priority","summary":"detailed","collaborationMode":{"mode":"plan","settings":{"model":"request-model","reasoning_effort":"low","developer_instructions":"Plan carefully."}},"multiAgentMode":{"custom":"ignored by this deprecated field"},"personality":"pragmatic"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id": 73, "result": {}}));

        let notification: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(notification["method"], "thread/settings/updated");
        assert_eq!(
            notification["params"]["threadId"],
            "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        );
        assert!(notification.get("kind").is_none());
        assert!(notification.get("sequence").is_none());
        assert!(notification["params"].get("emittedAtMs").is_none());
        let settings = &notification["params"]["threadSettings"];
        assert_eq!(
            settings
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>(),
            [
                "activePermissionProfile",
                "approvalPolicy",
                "approvalsReviewer",
                "collaborationMode",
                "cwd",
                "effort",
                "model",
                "modelProvider",
                "multiAgentMode",
                "personality",
                "sandboxPolicy",
                "serviceTier",
                "summary",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect()
        );
        assert!(settings["activePermissionProfile"].is_null());
        assert_eq!(
            settings["approvalPolicy"],
            serde_json::json!({
                "granular": {
                    "sandbox_approval": true,
                    "rules": false,
                    "skill_approval": false,
                    "request_permissions": false,
                    "mcp_elicitations": true,
                },
            })
        );
        assert_eq!(settings["approvalsReviewer"], "auto_review");
        assert_eq!(settings["cwd"], "/workspace/updated");
        assert_eq!(settings["model"], "request-model");
        assert_eq!(settings["modelProvider"], "openai");
        assert_eq!(settings["effort"], "low");
        assert_eq!(settings["serviceTier"], "priority");
        assert_eq!(settings["summary"], "detailed");
        assert_eq!(settings["personality"], "pragmatic");
        assert_eq!(
            settings["sandboxPolicy"],
            serde_json::json!({
                "type": "workspaceWrite",
                "writableRoots": [],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            })
        );
        assert_eq!(settings["collaborationMode"]["mode"], "plan");
        assert_eq!(
            settings["collaborationMode"]["settings"],
            serde_json::json!({
                "model": "request-model",
                "reasoning_effort": "low",
                "developer_instructions": "Plan carefully.",
            })
        );
        assert_eq!(settings["multiAgentMode"], "explicitRequestOnly");
        assert!(core.next_event().is_none());
    }

    #[test]
    fn thread_settings_update_rpc_distinguishes_omitted_null_and_value() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Patch semantics"},"metadata":{"sessionId":"settings-patch","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/original","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}
        core.request(
            br#"{"id":"initial","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/original","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly","networkAccess":true},"permissions":null,"model":"gpt-5.6","effort":"high","serviceTier":"priority","summary":"concise","personality":"friendly"}}"#,
        )
        .unwrap();
        let _ = core.next_event().unwrap();

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"null-patch","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","cwd":null,"approvalPolicy":null,"approvalsReviewer":null,"sandboxPolicy":null,"permissions":null,"model":null,"effort":null,"serviceTier":null,"summary":null,"collaborationMode":null,"multiAgentMode":"proactive","personality":null}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response,
            serde_json::json!({"id": "null-patch", "result": {}})
        );
        let notification: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        let settings = &notification["params"]["threadSettings"];
        assert_eq!(settings["cwd"], "/workspace/original");
        assert_eq!(settings["approvalPolicy"], "on-request");
        assert_eq!(settings["approvalsReviewer"], "user");
        assert_eq!(settings["sandboxPolicy"]["type"], "readOnly");
        assert_eq!(settings["sandboxPolicy"]["networkAccess"], true);
        assert!(settings["activePermissionProfile"].is_null());
        assert_eq!(settings["model"], "gpt-5.6");
        assert_eq!(settings["effort"], "high");
        assert_eq!(settings["serviceTier"], "default");
        assert_eq!(settings["summary"], "concise");
        assert_eq!(settings["personality"], "friendly");
        assert_eq!(settings["multiAgentMode"], "explicitRequestOnly");

        let sequence_before_noops = core.next_sequence;
        for request in [
            br#"{"id":"omitted","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#.as_slice(),
            br#"{"id":"ordinary-nulls","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","cwd":null,"approvalPolicy":null,"approvalsReviewer":null,"sandboxPolicy":null,"permissions":null,"model":null,"effort":null,"summary":null,"collaborationMode":null,"personality":null}}"#.as_slice(),
            br#"{"id":"deprecated-only","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","multiAgentMode":"proactive"}}"#.as_slice(),
        ] {
            let response: serde_json::Value =
                serde_json::from_slice(&core.request(request).unwrap()).unwrap();
            assert_eq!(response["result"], serde_json::json!({}));
            assert_eq!(core.next_sequence, sequence_before_noops);
            assert!(core.next_event().is_none());
        }

        core.request(
            br#"{"method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","permissions":":workspace","serviceTier":"flex"}}"#,
        )
        .unwrap();
        let valued: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(
            valued["params"]["threadSettings"]["activePermissionProfile"],
            serde_json::json!({"id": ":workspace", "extends": null})
        );
        assert_eq!(valued["params"]["threadSettings"]["serviceTier"], "flex");
    }

    #[test]
    fn thread_settings_update_rpc_persists_drives_resume_and_the_next_turn_and_is_atomic() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Durable settings"},"metadata":{"sessionId":"settings-durable","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/original","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        core.request(
            br#"{"id":"persist","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/persisted","approvalPolicy":"never","approvalsReviewer":"guardian_subagent","sandboxPolicy":{"type":"externalSandbox"},"model":"gpt-5.6","effort":"ultra","serviceTier":"priority","summary":"detailed","personality":"pragmatic"}}"#,
        )
        .unwrap();
        let expected_notification = core.next_event().unwrap();
        let sequence_after_update = core.next_sequence;
        let batch_count_after_update: i64 = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
            .unwrap();

        assert_eq!(
            core.request(
                br#"{"id":"reject","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","permissions":":workspace","sandboxPolicy":{"type":"dangerFullAccess"}}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence_after_update);
        assert!(core.next_event().is_none());
        let batch_count_after_rejection: i64 = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
            .unwrap();
        assert_eq!(batch_count_after_rejection, batch_count_after_update);
        drop(core);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = std::iter::from_fn(|| reopened.next_event()).collect();
        assert_eq!(replayed.last(), Some(&expected_notification));

        let resumed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"id":"resume","method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(resumed["id"], "resume");
        assert_eq!(resumed["result"]["cwd"], "/workspace/persisted");
        assert_eq!(resumed["result"]["model"], "gpt-5.6");
        assert_eq!(resumed["result"]["modelProvider"], "openai");
        assert_eq!(resumed["result"]["serviceTier"], "priority");
        assert_eq!(resumed["result"]["approvalPolicy"], "never");
        assert_eq!(resumed["result"]["approvalsReviewer"], "guardian_subagent");
        assert_eq!(
            resumed["result"]["sandbox"],
            serde_json::json!({"type": "externalSandbox", "networkAccess": "restricted"})
        );
        assert_eq!(resumed["result"]["reasoningEffort"], "ultra");

        let started: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"id":"next-turn","method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["result"]["turn"]["id"].as_str().unwrap();
        let effective = reopened
            .session
            .stable_turn_start_params(turn_id)
            .expect("updated settings must become the next turn's effective overrides");
        assert_eq!(effective["cwd"], "/workspace/persisted");
        assert_eq!(effective["model"], "gpt-5.6");
        assert_eq!(effective["serviceTier"], "priority");
        assert_eq!(effective["effort"], "ultra");
        assert_eq!(effective["approvalPolicy"], "never");
        assert_eq!(effective["approvalsReviewer"], "guardian_subagent");
        assert_eq!(
            effective["sandboxPolicy"],
            serde_json::json!({"type": "externalSandbox", "networkAccess": "restricted"})
        );
        assert_eq!(effective["summary"], "detailed");
        assert_eq!(effective["personality"], "pragmatic");
    }

    #[test]
    fn fresh_official_settings_patch_uses_full_baseline_and_canonical_thread_identity() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Fresh official settings"},"metadata":{"sessionId":"fresh-settings","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/original","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let request = serde_json::to_vec(&serde_json::json!({
            "id": "fresh-partial",
            "method": "thread/settings/update",
            "params": {
                "threadId": "abcdefab-cdef-4abc-8def-abcdefabcdef",
                "cwd": ".",
                "permissions": ":read-only",
            },
        }))
        .unwrap();
        core.request(&request).unwrap();

        let notification: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(notification["method"], "thread/settings/updated");
        assert_eq!(
            notification["params"]["threadId"],
            "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        );
        let settings = &notification["params"]["threadSettings"];
        assert_eq!(
            settings["cwd"],
            std::env::current_dir().unwrap().to_string_lossy().as_ref()
        );
        assert_eq!(settings["approvalPolicy"], "on-request");
        assert_eq!(settings["approvalsReviewer"], "user");
        assert_eq!(settings["model"], "gpt-5.6-sol");
        assert_eq!(settings["modelProvider"], "openai");
        assert_eq!(settings["effort"], "low");
        assert_eq!(
            settings["activePermissionProfile"],
            serde_json::json!({"id": ":read-only", "extends": null})
        );
        assert_eq!(
            settings["sandboxPolicy"],
            serde_json::json!({"type": "readOnly", "networkAccess": false})
        );

        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"case-insensitive-turn","method":"turn/start","params":{"threadId":"abcdefab-cdef-4abc-8def-abcdefabcdef","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["result"]["turn"]["id"].as_str().unwrap();
        let effective = core.session.stable_turn_start_params(turn_id).unwrap();
        assert_eq!(
            effective["threadId"],
            "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        );
        assert_eq!(effective["cwd"], settings["cwd"]);
    }

    #[test]
    fn turn_start_settings_overrides_are_sticky_and_only_real_changes_notify() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        while core.next_event().is_some() {}

        let first = serde_json::to_vec(&serde_json::json!({
            "id": "first",
            "method": "turn/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "input": [],
                "model": "gpt-base",
                "effort": "low",
                "serviceTier": null,
                "collaborationMode": {
                    "mode": "plan",
                    "settings": {
                        "model": "gpt-plan",
                        "reasoning_effort": "high",
                        "developer_instructions": "Keep the plan explicit.",
                    },
                },
            },
        }))
        .unwrap();
        core.request(&first).unwrap();
        let changed: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(changed["method"], "thread/settings/updated");
        let settings = &changed["params"]["threadSettings"];
        assert_eq!(settings["model"], "gpt-plan");
        assert_eq!(settings["effort"], "high");
        assert_eq!(settings["serviceTier"], "default");
        assert_eq!(settings["collaborationMode"]["mode"], "plan");
        assert_eq!(
            settings["collaborationMode"]["settings"]["developer_instructions"],
            "Keep the plan explicit."
        );
        let first_started: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(first_started["kind"], "stableTurnStarted");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&core.next_event().unwrap()).unwrap()["method"],
            "thread/status/changed"
        );
        assert!(core.next_event().is_none());

        let second: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"second","method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let second_turn_id = second["result"]["turn"]["id"].as_str().unwrap();
        let inherited = core
            .session
            .stable_turn_start_params(second_turn_id)
            .unwrap();
        assert_eq!(inherited["model"], "gpt-plan");
        assert_eq!(inherited["effort"], "high");
        assert_eq!(inherited["collaborationMode"]["mode"], "plan");
        assert!(
            inherited.get("serviceTier").is_none(),
            "effective default service tier must remain omitted downstream"
        );
        let second_started: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(second_started["kind"], "stableTurnStarted");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&core.next_event().unwrap()).unwrap()["method"],
            "thread/status/changed"
        );
        assert!(core.next_event().is_none());

        let third = serde_json::to_vec(&serde_json::json!({
            "id": "third",
            "method": "turn/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "input": [],
                "collaborationMode": {
                    "mode": "default",
                    "settings": {
                        "model": "gpt-default",
                        "reasoning_effort": "medium",
                    },
                },
            },
        }))
        .unwrap();
        core.request(&third).unwrap();
        let override_notification: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(override_notification["method"], "thread/settings/updated");
        assert_eq!(
            override_notification["params"]["threadSettings"]["model"],
            "gpt-default"
        );
        assert_eq!(
            override_notification["params"]["threadSettings"]["effort"],
            "medium"
        );
        assert_eq!(
            override_notification["params"]["threadSettings"]["collaborationMode"]["mode"],
            "default"
        );
        let third_started: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(third_started["kind"], "stableTurnStarted");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&core.next_event().unwrap()).unwrap()["method"],
            "thread/status/changed"
        );
        assert!(core.next_event().is_none());
    }

    #[test]
    fn settings_patch_is_typed_bounded_and_rejects_unknown_permission_profiles_atomically() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        while core.next_event().is_some() {}
        core.request(
            br#"{"id":"baseline","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","model":"gpt-5.6-terra"}}"#,
        )
        .unwrap();
        let _ = core.next_event().unwrap();
        let sequence = core.next_sequence;

        assert_eq!(
            core.request(
                br#"{"id":"unknown-field","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","model":"gpt-5.6-sol","amplification":{"repeat":"forever"}}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            core.request(
                br#"{"id":"unknown-profile","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","permissions":"local-unresolved-profile"}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        let oversized = serde_json::to_vec(&serde_json::json!({
            "id": "oversized",
            "method": "thread/settings/update",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "model": "x".repeat(70 * 1024),
            },
        }))
        .unwrap();
        assert_eq!(core.request(&oversized), Err(CoreError::InvalidArgument));
        assert_eq!(core.next_sequence, sequence);
        assert!(core.next_event().is_none());

        core.request(
            br#"{"id":"same","method":"thread/settings/update","params":{"threadId":"00000000-0000-0000-0000-000000000002","model":"gpt-5.6-terra"}}"#,
        )
        .unwrap();
        assert_eq!(core.next_sequence, sequence);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn thread_fork_inherits_the_source_goal_without_starting_a_turn() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"}}"#.as_slice(),
            br#"{"kind":"thread.goal.set","threadId":"00000000-0000-0000-0000-000000000002","objective":"Ship","status":"active","tokenBudget":12000}"#.as_slice(),
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000006","title":"Task (fork)","lastTurnId":null,"turnIdMap":{},"itemIdMap":{}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(events.len(), 5);
        let source: serde_json::Value = serde_json::from_slice(&events[2]).unwrap();
        let forked: serde_json::Value = serde_json::from_slice(&events[4]).unwrap();
        assert_eq!(forked["kind"], "threadGoalUpdated");
        assert_eq!(forked["goal"]["objective"], source["goal"]["objective"]);
        assert_eq!(forked["goal"]["tokenBudget"], source["goal"]["tokenBudget"]);
        assert_eq!(forked["goal"]["createdAt"], source["goal"]["createdAt"]);
        assert_eq!(
            forked["goal"]["threadId"],
            "00000000-0000-0000-0000-000000000006"
        );
    }

    #[test]
    fn thread_fork_inherits_effective_settings_with_the_new_thread_identity() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Task"},"metadata":{"sessionId":"settings-fork","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace","model":"gpt-5.4","effort":"ultra","approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","networkAccess":true,"writableRoots":["/workspace"],"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}}"#.as_slice(),
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000006","title":"Task (fork)","lastTurnId":null,"turnIdMap":{},"itemIdMap":{},"timestamp":101}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        let inherited = events
            .iter()
            .find(|event| {
                event["kind"] == "threadSettingsUpdated"
                    && event["threadId"] == "00000000-0000-0000-0000-000000000006"
            })
            .expect("fork must publish inherited settings");
        assert_eq!(inherited["threadSettings"]["cwd"], "/workspace");
        assert_eq!(inherited["threadSettings"]["model"], "gpt-5.4");
        assert_eq!(inherited["threadSettings"]["modelProvider"], "openai");
        assert_eq!(inherited["threadSettings"]["effort"], "ultra");
        assert_eq!(
            inherited["threadSettings"]["sandboxPolicy"]["networkAccess"],
            true
        );
    }

    #[test]
    fn running_turn_accepts_activity_items_before_completion() {
        let mut core = CodexCore::default();
        let commands: [&[u8]; 5] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect this project"}}"#,
            br#"{"kind":"item.append","item":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"toolCall","text":"Reading Sources/App.swift"}}"#,
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000003","assistantItem":{"id":"00000000-0000-0000-0000-000000000006","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Done"}}"#,
        ];
        for command in commands {
            core.submit(command).unwrap();
        }
        let events: Vec<Vec<u8>> = std::iter::from_fn(|| core.next_event()).collect();
        assert_eq!(events.len(), 7);
        assert_eq!(
            events[4],
            br#"{"sequence":5,"kind":"itemAppended","item":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"toolCall","text":"Reading Sources/App.swift"}}"#
        );
    }

    #[test]
    fn session_flow_rejections_leave_sequence_and_queue_atomic() {
        let mut core = CodexCore::default();
        assert_eq!(
            core.submit(
                br#"{"kind":"workspace.open","workspace":{"id":"not-a-uuid","displayName":"Mars","rootBookmarkId":null}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            core.submit(
                br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"","rootBookmarkId":null}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert!(core.next_event().is_none());

        core.submit(
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#
        ).unwrap();
        assert!(core.next_event().unwrap().starts_with(br#"{"sequence":1,"#));

        assert_eq!(
            core.submit(
                br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(
            core.submit(
                br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-999999999999","title":"First task"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert!(core.next_event().is_none());

        core.submit(
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#
        ).unwrap();
        assert!(core.next_event().unwrap().starts_with(br#"{"sequence":2,"#));

        assert_eq!(
            core.submit(
                br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":""}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert!(core.next_event().is_none());
    }

    #[test]
    fn official_thread_fork_requires_timestamp_atomically() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let sequence_before = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000005","title":"Forked task","lastTurnId":null,"turnIdMap":{},"itemIdMap":{}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence_before);
        assert!(core.next_event().is_none());
        assert_eq!(
            core.request(
                br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000005"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn official_turn_start_requires_timestamp_atomically() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let sequence_before = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000006","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000005","kind":"userMessage","text":"Inspect the official thread"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence_before);
        assert!(core.next_event().is_none());
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["thread"]["turns"], serde_json::json!([]));
        assert_eq!(response["thread"]["status"]["type"], "idle");
    }

    #[test]
    fn official_turn_complete_requires_timestamp_atomically() {
        let mut core = official_core_with_running_turn();
        let sequence_before = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000005","assistantItem":{"id":"00000000-0000-0000-0000-000000000007","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000005","kind":"assistantMessage","text":"Finished"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_official_turn_rejection_is_atomic(&mut core, sequence_before);
    }

    #[test]
    fn official_turn_fail_requires_timestamp_atomically() {
        let mut core = official_core_with_running_turn();
        let sequence_before = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"turn.fail","turnId":"00000000-0000-0000-0000-000000000005","errorItem":{"id":"00000000-0000-0000-0000-000000000007","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000005","kind":"error","text":"Request failed"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_official_turn_rejection_is_atomic(&mut core, sequence_before);
    }

    #[test]
    fn official_turn_cancel_requires_timestamp_atomically() {
        let mut core = official_core_with_running_turn();
        let sequence_before = core.next_sequence;

        assert_eq!(
            core.submit(
                br#"{"kind":"turn.cancel","turnId":"00000000-0000-0000-0000-000000000005"}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_official_turn_rejection_is_atomic(&mut core, sequence_before);
    }

    #[test]
    fn sqlite_storage_replays_committed_events_after_restart() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = format!(
            r#"{{"kind":"storage.open","databasePath":{},"snapshotDirectory":{}}}"#,
            serde_json::to_string(database.to_str().unwrap()).unwrap(),
            serde_json::to_string(snapshots.to_str().unwrap()).unwrap()
        );
        let workspace = br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":"BASE64_BOOKMARK_SAMPLE"}}"#;

        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        first.submit(workspace).unwrap();
        let expected = first.next_event().unwrap();
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        assert_eq!(reopened.next_event().unwrap(), expected);
        let replayed: serde_json::Value = serde_json::from_slice(&expected).unwrap();
        assert_eq!(
            replayed["workspace"]["rootBookmarkId"],
            "BASE64_BOOKMARK_SAMPLE"
        );
        assert!(reopened.next_event().is_none());
    }

    #[test]
    fn remote_control_enrollment_load_returns_null_for_normalized_nil_client_name() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();

        let response = core
            .request(
                br#"{"id":"load-empty","method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":null}}"#,
            )
            .unwrap();

        assert_eq!(
            response,
            br#"{"id":"load-empty","result":{"enrollment":null}}"#
        );
    }

    #[test]
    fn remote_control_enrollment_upsert_round_trips_only_durable_fields() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        let open = storage_open_command(&database, &snapshots);
        core.submit(open.as_bytes()).unwrap();

        core.submit(
            br#"{"kind":"remote_control.enrollment.upsert","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":null,"serverId":"server-1","environmentId":"environment-1","serverName":"Codex for ipad","updatedAt":10,"remoteControlToken":"TRANSIENT_REMOTE_TOKEN","expiresAt":99,"refreshToken":"TRANSIENT_REFRESH_TOKEN","cursor":"TRANSIENT_CURSOR","tasks":["TRANSIENT_TASK"]}"#,
        )
        .unwrap();
        drop(core);
        let database_bytes = std::fs::read(&database).unwrap();
        assert!(
            !database_bytes
                .windows(b"TRANSIENT_".len())
                .any(|window| window == b"TRANSIENT_")
        );

        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        let response = core
            .request(
                br#"{"id":"load-upserted","method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1"}}"#,
            )
            .unwrap();
        let decoded: serde_json::Value = serde_json::from_slice(&response).unwrap();

        assert_eq!(decoded["id"], "load-upserted");
        assert_eq!(
            decoded["result"]["enrollment"],
            serde_json::json!({
                "websocketUrl": "wss://one.test/ws",
                "accountId": "account-1",
                "appServerClientName": "",
                "serverId": "server-1",
                "environmentId": "environment-1",
                "serverName": "Codex for ipad",
                "updatedAt": 10,
                "remoteControlEnabled": null,
            })
        );
        let durable_json = decoded["result"]["enrollment"].to_string();
        assert!(!durable_json.contains("TRANSIENT_"));
        assert!(core.next_event().is_none());
    }

    #[test]
    fn remote_control_enrollment_upsert_inserts_enabled_once_and_preserves_it_on_conflict() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();

        core.submit(
            br#"{"kind":"remote_control.enrollment.upsert","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1","serverId":"server-old","environmentId":"environment-old","serverName":"Codex old","updatedAt":10,"remoteControlEnabled":true}"#,
        )
        .unwrap();
        let inserted = core
            .request(
                br#"{"method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1"}}"#,
            )
            .unwrap();
        let inserted: serde_json::Value = serde_json::from_slice(&inserted).unwrap();
        assert_eq!(
            inserted["enrollment"]["remoteControlEnabled"],
            serde_json::Value::Bool(true)
        );

        core.submit(
            br#"{"kind":"remote_control.enrollment.upsert","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1","serverId":"server-new","environmentId":"environment-new","serverName":"Codex new","updatedAt":20,"remoteControlEnabled":false}"#,
        )
        .unwrap();
        let refreshed = core
            .request(
                br#"{"method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1"}}"#,
            )
            .unwrap();
        let refreshed: serde_json::Value = serde_json::from_slice(&refreshed).unwrap();
        assert_eq!(refreshed["enrollment"]["serverId"], "server-new");
        assert_eq!(refreshed["enrollment"]["environmentId"], "environment-new");
        assert_eq!(refreshed["enrollment"]["serverName"], "Codex new");
        assert_eq!(refreshed["enrollment"]["updatedAt"], 20);
        assert_eq!(
            refreshed["enrollment"]["remoteControlEnabled"],
            serde_json::Value::Bool(true)
        );
        assert!(core.next_event().is_none());
    }

    #[test]
    fn remote_control_enrollment_set_enabled_updates_flag_and_timestamp() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();
        core.submit(
            br#"{"kind":"remote_control.enrollment.upsert","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1","serverId":"server-1","environmentId":"environment-1","serverName":"Codex for ipad","updatedAt":10}"#,
        )
        .unwrap();

        core.submit(
            br#"{"kind":"remote_control.enrollment.set_enabled","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1","enabled":true,"updatedAt":20}"#,
        )
        .unwrap();
        let response = core
            .request(
                br#"{"method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1"}}"#,
            )
            .unwrap();
        let decoded: serde_json::Value = serde_json::from_slice(&response).unwrap();

        assert_eq!(
            decoded["enrollment"]["remoteControlEnabled"],
            serde_json::Value::Bool(true)
        );
        assert_eq!(decoded["enrollment"]["updatedAt"], 20);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn remote_control_enrollment_delete_uses_the_exact_composite_key() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();
        for (client_name, server_id) in [("", "server-default"), ("client-1", "server-client")] {
            let command = serde_json::json!({
                "kind": "remote_control.enrollment.upsert",
                "websocketUrl": "wss://one.test/ws",
                "accountId": "account-1",
                "appServerClientName": client_name,
                "serverId": server_id,
                "environmentId": "environment-1",
                "serverName": "Codex for ipad",
                "updatedAt": 10,
            });
            core.submit(&serde_json::to_vec(&command).unwrap()).unwrap();
        }

        core.submit(
            br#"{"kind":"remote_control.enrollment.delete","websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":null}"#,
        )
        .unwrap();
        let deleted = core
            .request(
                br#"{"method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1"}}"#,
            )
            .unwrap();
        let retained = core
            .request(
                br#"{"method":"remote_control.enrollment.load","params":{"websocketUrl":"wss://one.test/ws","accountId":"account-1","appServerClientName":"client-1"}}"#,
            )
            .unwrap();

        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&deleted).unwrap()["enrollment"],
            serde_json::Value::Null
        );
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&retained).unwrap()["enrollment"]["serverId"],
            "server-client"
        );
        assert!(core.next_event().is_none());
    }

    #[test]
    fn sqlite_storage_replays_a_fork_with_identical_history_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let commands: [&[u8]; 5] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000003","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000004","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"userMessage","text":"Inspect"}}"#,
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000003","assistantItem":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000003","kind":"assistantMessage","text":"Done"}}"#,
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000006","title":"First task (fork)","lastTurnId":null,"turnIdMap":{"00000000-0000-0000-0000-000000000003":"00000000-0000-0000-0000-000000000007"},"itemIdMap":{"00000000-0000-0000-0000-000000000004":"00000000-0000-0000-0000-000000000008","00000000-0000-0000-0000-000000000005":"00000000-0000-0000-0000-000000000009"}}"#,
        ];
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        for command in commands {
            first.submit(command).unwrap();
        }
        let expected: Vec<Vec<u8>> = std::iter::from_fn(|| first.next_event()).collect();
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = std::iter::from_fn(|| reopened.next_event()).collect();
        assert_eq!(replayed, expected);
    }

    #[test]
    fn sqlite_storage_replays_thread_goal_state_for_later_clear() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let commands: [&[u8]; 3] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"}}"#,
            br#"{"kind":"thread.goal.set","threadId":"00000000-0000-0000-0000-000000000002","objective":"Finish the port","status":"paused","tokenBudget":12000}"#,
        ];
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        for command in commands {
            first.submit(command).unwrap();
        }
        let expected: Vec<Vec<u8>> = std::iter::from_fn(|| first.next_event()).collect();
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = (0..expected.len())
            .map(|_| reopened.next_event().unwrap())
            .collect();
        assert_eq!(replayed, expected);
        reopened
            .submit(
                br#"{"kind":"thread.goal.clear","threadId":"00000000-0000-0000-0000-000000000002"}"#,
            )
            .unwrap();
        assert_eq!(
            reopened.next_event().unwrap(),
            br#"{"sequence":4,"kind":"threadGoalCleared","threadId":"00000000-0000-0000-0000-000000000002"}"#
        );
        assert!(reopened.next_event().is_none());
    }

    #[test]
    fn sqlite_storage_replays_thread_settings_and_applies_partial_patch() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let commands: [&[u8]; 3] = [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#,
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"},"metadata":{"sessionId":"settings-storage","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#,
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace","model":"gpt-5.4","effort":"high","approvalPolicy":"on-request","sandboxPolicy":{"type":"workspaceWrite","networkAccess":false,"writableRoots":[],"excludeTmpdirEnvVar":false,"excludeSlashTmp":false}}"#,
        ];
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        for command in commands {
            first.submit(command).unwrap();
        }
        let expected: Vec<Vec<u8>> = std::iter::from_fn(|| first.next_event()).collect();
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = (0..expected.len())
            .map(|_| reopened.next_event().unwrap())
            .collect();
        assert_eq!(replayed, expected);
        reopened
            .submit(
                br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","effort":"ultra"}"#,
            )
            .unwrap();
        let patched: serde_json::Value =
            serde_json::from_slice(&reopened.next_event().unwrap()).unwrap();
        assert_eq!(patched["sequence"], 4);
        assert_eq!(patched["kind"], "threadSettingsUpdated");
        assert_eq!(patched["threadSettings"]["cwd"], "/workspace");
        assert_eq!(patched["threadSettings"]["model"], "gpt-5.4");
        assert_eq!(patched["threadSettings"]["effort"], "ultra");
        assert_eq!(patched["threadSettings"]["approvalPolicy"], "on-request");
        assert!(reopened.next_event().is_none());
    }

    #[test]
    fn sqlite_storage_rejects_corrupt_persisted_event_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let workspace = br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#;

        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        first.submit(workspace).unwrap();
        drop(first);

        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute(
                "UPDATE event_batches SET events_jsonl = ?1",
                [b"not-json".as_slice()],
            )
            .unwrap();
        drop(connection);

        let mut reopened = CodexCore::default();
        assert_eq!(reopened.submit(open.as_bytes()), Err(CoreError::Storage));
        assert!(reopened.next_event().is_none());
    }

    #[test]
    fn rejected_session_command_is_not_persisted_or_sequenced() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        assert_eq!(
            first.submit(
                br#"{"kind":"workspace.open","workspace":{"id":"bad","displayName":"Mars","rootBookmarkId":null}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        first
            .submit(
                br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#
            )
            .unwrap();
        assert!(
            first
                .next_event()
                .unwrap()
                .starts_with(br#"{"sequence":1,"#)
        );
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        assert!(
            reopened
                .next_event()
                .unwrap()
                .starts_with(br#"{"sequence":1,"#)
        );
        assert!(reopened.next_event().is_none());
    }

    #[test]
    fn legacy_schema_snapshot_survives_restart_until_confirmation() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let connection = rusqlite::Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE legacy(value TEXT NOT NULL);
                 INSERT INTO legacy(value) VALUES('preserve-me');
                 PRAGMA user_version = 0;",
            )
            .unwrap();
        drop(connection);

        let open = storage_open_command(&database, &snapshots);
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        drop(first);
        let snapshot = snapshots.join("schema-0-to-3.sqlite");
        assert!(snapshot.is_file());
        let snapshot_connection = rusqlite::Connection::open(&snapshot).unwrap();
        let preserved: String = snapshot_connection
            .query_row("SELECT value FROM legacy", [], |row| row.get(0))
            .unwrap();
        assert_eq!(preserved, "preserve-me");
        drop(snapshot_connection);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        assert!(snapshot.is_file());
        reopened.submit(br#"{"kind":"storage.confirm"}"#).unwrap();
        assert!(!snapshot.exists());
    }

    #[test]
    fn owned_snapshot_can_restore_an_earlier_event_log() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let first_workspace = br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"First","rootBookmarkId":null}}"#;
        let second_workspace = br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000002","displayName":"Second","rootBookmarkId":null}}"#;
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        first.submit(first_workspace).unwrap();
        drop(first);

        std::fs::create_dir_all(&snapshots).unwrap();
        std::fs::copy(&database, snapshots.join("manual.sqlite")).unwrap();
        let mut second = CodexCore::default();
        second.submit(open.as_bytes()).unwrap();
        let _ = second.next_event();
        second.submit(second_workspace).unwrap();
        drop(second);

        let restore = format!(
            r#"{{"kind":"storage.restore","databasePath":{},"snapshotDirectory":{},"snapshotName":"manual.sqlite"}}"#,
            serde_json::to_string(database.to_str().unwrap()).unwrap(),
            serde_json::to_string(snapshots.to_str().unwrap()).unwrap()
        );
        let mut restored = CodexCore::default();
        restored.submit(restore.as_bytes()).unwrap();
        let event = restored.next_event().unwrap();
        assert!(
            event
                .windows(b"First".len())
                .any(|window| window == b"First")
        );
        assert!(restored.next_event().is_none());
    }

    #[test]
    fn snapshot_restore_rejects_directory_traversal() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        std::fs::create_dir_all(&snapshots).unwrap();
        let restore = format!(
            r#"{{"kind":"storage.restore","databasePath":{},"snapshotDirectory":{},"snapshotName":"../outside.sqlite"}}"#,
            serde_json::to_string(database.to_str().unwrap()).unwrap(),
            serde_json::to_string(snapshots.to_str().unwrap()).unwrap()
        );
        assert_eq!(
            CodexCore::default().submit(restore.as_bytes()),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn thread_resume_preserves_the_stored_id_projects_all_turns_and_emits_no_event() {
        let mut core = CodexCore::default();
        let thread_id = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF";
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Resume exact ID"},"metadata":{"sessionId":"session-tree-exact","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/exact","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"Resume this exact stored thread"},"timestamp":101}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"Stored history restored"},"timestamp":102}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}
        let sequence_before_resume = core.next_sequence;

        assert_eq!(
            core.request(
                br#"{"method":"thread/resume","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"resume-exact","method":"thread/resume","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","model":"gpt-5.6-sol","modelProvider":"openai","approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write"}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "resume-exact");
        assert_eq!(response["result"]["thread"]["id"], thread_id);
        assert_eq!(
            response["result"]["thread"]["sessionId"],
            "session-tree-exact"
        );
        assert_eq!(
            response["result"]["thread"]["turns"][0]["items"][0]["content"][0]["text"],
            "Resume this exact stored thread"
        );
        assert_eq!(
            response["result"]["thread"]["turns"][0]["items"][1]["text"],
            "Stored history restored"
        );
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["modelProvider"], "openai");
        assert!(response["result"]["serviceTier"].is_null());
        assert_eq!(response["result"]["cwd"], "/workspace/exact");
        assert_eq!(response["result"]["approvalPolicy"], "on-request");
        assert_eq!(response["result"]["approvalsReviewer"], "user");
        assert_eq!(response["result"]["sandbox"]["type"], "workspaceWrite");
        assert!(response["result"]["reasoningEffort"].is_null());
        assert_eq!(core.next_sequence, sequence_before_resume);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn thread_resume_returns_persisted_effective_settings() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/settings","model":"gpt-5.4","effort":"ultra","approvalPolicy":{"granular":{"sandbox_approval":true,"rules":false,"skill_approval":true,"request_permissions":false,"mcp_elicitations":true}},"approvalsReviewer":"auto_review","sandboxPolicy":{"type":"externalSandbox","networkAccess":"enabled"},"serviceTier":"priority"}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["model"], "gpt-5.4");
        assert_eq!(response["modelProvider"], "openai");
        assert_eq!(response["serviceTier"], "priority");
        assert_eq!(response["cwd"], "/workspace/settings");
        assert_eq!(response["approvalPolicy"]["granular"]["rules"], false);
        assert_eq!(response["approvalsReviewer"], "auto_review");
        assert_eq!(response["sandbox"]["type"], "externalSandbox");
        assert_eq!(response["sandbox"]["networkAccess"], "enabled");
        assert_eq!(response["reasoningEffort"], "ultra");
        assert_eq!(response["instructionSources"], serde_json::json!([]));
    }

    #[test]
    fn cold_thread_resume_accepts_the_released_renderer_request_shape() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let thread_id = "00000000-0000-0000-0000-000000000002";

        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/old/container/Documents/project","model":"gpt-5.6-sol","effort":"low","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"serviceTier":"default","personality":"friendly"}"#,
        )
        .unwrap();
        drop(core);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let response: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"id":"released-renderer","method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","history":null,"path":null,"model":null,"modelProvider":"openai","cwd":"/current/container/Documents/project","personality":"friendly","excludeTurns":false}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "released-renderer");
        assert_eq!(response["result"]["thread"]["id"], thread_id);
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["modelProvider"], "openai");
        assert_eq!(
            response["result"]["cwd"],
            "/current/container/Documents/project"
        );
    }

    #[test]
    fn cold_thread_resume_accepts_full_released_renderer_setting_echo() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let thread_id = "00000000-0000-0000-0000-000000000002";

        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/current/container/Documents/project","model":"gpt-5.6-sol","effort":"low","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"serviceTier":"default","personality":"friendly","collaborationMode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":"low","developer_instructions":"Keep the persisted behavior."}}}"#,
        )
        .unwrap();
        drop(core);

        let renderer_params = serde_json::json!({
            "threadId": thread_id,
            "history": null,
            "model": null,
            "modelProvider": null,
            "cwd": "/current/container/Documents/project",
            "developerInstructions": "Keep the persisted behavior.",
            "personality": "friendly",
            "excludeTurns": false,
            "initialTurnsPage": null,
            "config": {
                "ambient-suggestions-enabled": false,
                "conversationDetailMode": "default",
                "features": {},
                "features.apps_mcp_path_override": false,
                "features.collaboration_modes": true,
                "features.concurrent_reasoning_summaries": true,
                "features.enable_mcp_apps": true,
                "features.executed_tool_call_metadata": true,
                "features.guardian_approval": true,
                "features.image_detail_original": true,
                "features.image_generation": true,
                "features.item_ids": true,
                "features.realtime_conversation": true,
                "features.remote_compaction_v2": true,
                "features.request_rule": true,
                "features.thread_tools": true,
                "features.workspace_dependencies": true,
                "hotkey-window-projectless-default-enabled": false,
                "localeOverride": null,
                "memories": {},
                "model": "gpt-5.6-sol",
                "model_reasoning_effort": "low",
                "show-context-window-usage": true
            }
        });

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let response: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "released-renderer-full",
                        "method": "thread/resume",
                        "params": renderer_params,
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "released-renderer-full");
        assert_eq!(response["result"]["thread"]["id"], thread_id);
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["modelProvider"], "openai");
        assert_eq!(response["result"]["reasoningEffort"], "low");

        let mut changed_instructions = renderer_params.clone();
        changed_instructions["developerInstructions"] = serde_json::json!("Changed behavior.");
        assert_eq!(
            reopened.request(
                serde_json::to_string(&serde_json::json!({
                    "method": "thread/resume",
                    "params": changed_instructions,
                }))
                .unwrap()
                .as_bytes(),
            ),
            Err(CoreError::InvalidArgument)
        );

        let mut changed_model = renderer_params;
        changed_model["config"]["model"] = serde_json::json!("different-model");
        assert_eq!(
            reopened.request(
                serde_json::to_string(&serde_json::json!({
                    "method": "thread/resume",
                    "params": changed_model,
                }))
                .unwrap()
                .as_bytes(),
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn cold_thread_resume_accepts_released_renderer_hydration_when_persisted_instructions_are_null()
    {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let thread_id = "00000000-0000-0000-0000-000000000002";

        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/current/container/Documents/project","model":"gpt-5.6-sol","effort":"low","approvalPolicy":"never","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"serviceTier":"default","personality":"friendly","collaborationMode":{"mode":"default","settings":{"model":"gpt-5.6-sol","reasoning_effort":"low","developer_instructions":null}}}"#,
        )
        .unwrap();
        drop(core);

        let renderer_params = serde_json::json!({
            "threadId": thread_id,
            "history": null,
            "path": null,
            "model": null,
            "modelProvider": null,
            "cwd": "/current/container/Documents/project",
            "developerInstructions": "Use the released renderer environment.",
            "personality": "friendly",
            "excludeTurns": false,
            "initialTurnsPage": null,
            "config": {
                "ambient-suggestions-enabled": false,
                "conversationDetailMode": "default",
                "features": {},
                "features.collaboration_modes": true,
                "features.thread_tools": true,
                "localeOverride": null,
                "memories": {},
                "model": "gpt-5.6-sol",
                "model_reasoning_effort": "low",
                "show-context-window-usage": true
            }
        });

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let response: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "released-renderer-null-instructions",
                        "method": "thread/resume",
                        "params": renderer_params,
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "released-renderer-null-instructions");
        assert_eq!(response["result"]["thread"]["id"], thread_id);
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["modelProvider"], "openai");
        assert_eq!(response["result"]["reasoningEffort"], "low");
    }

    #[test]
    fn thread_resume_decodes_complete_stable_overrides_without_mutating_stored_settings() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/original","model":"gpt-5.4","effort":"high","approvalPolicy":"on-request","approvalsReviewer":"auto_review","sandboxPolicy":{"type":"readOnly","networkAccess":false},"serviceTier":"priority"}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        let sequence_before_resume = core.next_sequence;

        let overridden: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","model":"gpt-5.5","modelProvider":"custom-provider","serviceTier":null,"cwd":"/workspace/override","approvalPolicy":"never","approvalsReviewer":"user","sandbox":"danger-full-access"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(overridden["model"], "gpt-5.5");
        assert_eq!(overridden["modelProvider"], "custom-provider");
        assert!(overridden["serviceTier"].is_null());
        assert_eq!(overridden["cwd"], "/workspace/override");
        assert_eq!(overridden["approvalPolicy"], "never");
        assert_eq!(overridden["approvalsReviewer"], "user");
        assert_eq!(overridden["sandbox"]["type"], "dangerFullAccess");

        let persisted: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(persisted["model"], "gpt-5.4");
        assert_eq!(persisted["modelProvider"], "openai");
        assert_eq!(persisted["serviceTier"], "priority");
        assert_eq!(persisted["cwd"], "/workspace/original");
        assert_eq!(persisted["approvalPolicy"], "on-request");
        assert_eq!(persisted["approvalsReviewer"], "auto_review");
        assert_eq!(persisted["sandbox"]["type"], "readOnly");
        assert_eq!(core.next_sequence, sequence_before_resume);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn thread_resume_rejects_unknown_legacy_and_malformed_requests_atomically() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000099","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Legacy thread"}}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        let sequence_before_resume = core.next_sequence;

        for invalid in [
            br#"{"method":"thread/resume","params":{"threadId":"missing-thread"}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000099"}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","model":42}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","sandbox":"unsupported"}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","config":{"feature":{"enabled":true}}}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","baseInstructions":"Base instructions"}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","developerInstructions":"Developer instructions"}}"#.as_slice(),
            br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","personality":"friendly"}}"#.as_slice(),
        ] {
            assert_eq!(core.request(invalid), Err(CoreError::InvalidArgument));
        }

        assert_eq!(core.next_sequence, sequence_before_resume);
        assert!(core.next_event().is_none());
        let known: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            known["thread"]["id"],
            "00000000-0000-0000-0000-000000000002"
        );
    }

    #[test]
    fn stable_turn_start_returns_initial_turn_and_preserves_user_input_on_read() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Exact raw ID"},"metadata":{"sessionId":"turn-start-exact","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/exact","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}
        let sequence_before_start = core.next_sequence;

        let request = serde_json::to_vec(&serde_json::json!({
            "id": "start-exact",
            "method": "turn/start",
            "params": {
                "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
                "clientUserMessageId": "client-message-1",
                "input": [{
                    "type": "text",
                    "text": "你好🦀",
                    "text_elements": [{
                        "byteRange": {"start": 0, "end": 6},
                        "placeholder": "问候",
                    }],
                }],
            },
        }))
        .unwrap();
        let response: serde_json::Value =
            serde_json::from_slice(&core.request(&request).unwrap()).unwrap();

        assert_eq!(response["id"], "start-exact");
        let turn = &response["result"]["turn"];
        let turn_id = turn["id"].as_str().unwrap();
        assert_eq!(turn_id.len(), 36);
        assert_eq!(&turn_id[14..15], "7");
        assert!(matches!(&turn_id[19..20], "8" | "9" | "a" | "b"));
        assert_eq!(turn["items"], serde_json::json!([]));
        assert_eq!(turn["itemsView"], "notLoaded");
        assert_eq!(turn["status"], "inProgress");
        assert!(turn["error"].is_null());
        assert!(turn["startedAt"].is_null());
        assert!(turn["completedAt"].is_null());
        assert!(turn["durationMs"].is_null());
        assert_eq!(core.next_sequence, sequence_before_start + 1);
        let started_event: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(started_event["kind"], "stableTurnStarted");
        assert_eq!(
            started_event["threadId"],
            "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        );
        assert_eq!(started_event["turnId"], turn_id);
        let status_event: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(status_event["method"], "thread/status/changed");
        assert_eq!(
            status_event["params"],
            serde_json::json!({
                "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
                "status": {"type": "active", "activeFlags": []},
            })
        );
        assert!(core.next_event().is_none());

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let persisted_turn = &read["thread"]["turns"][0];
        assert_eq!(persisted_turn["id"], turn_id);
        assert_eq!(persisted_turn["status"], "inProgress");
        assert_eq!(persisted_turn["itemsView"], "summary");
        assert_eq!(persisted_turn["items"][0]["clientId"], "client-message-1");
        assert_eq!(persisted_turn["items"][0]["content"][0]["text"], "你好🦀");
        assert_eq!(
            persisted_turn["items"][0]["content"][0]["text_elements"][0]["byteRange"],
            serde_json::json!({"start": 0, "end": 6})
        );
        assert_eq!(
            persisted_turn["items"][0]["content"][0]["text_elements"][0]["placeholder"],
            "问候"
        );
    }

    #[test]
    fn stable_turn_start_allows_empty_input() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let sequence_before_start = core.next_sequence;

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["turn"]["items"], serde_json::json!([]));
        assert_eq!(response["turn"]["itemsView"], "notLoaded");
        assert_eq!(response["turn"]["status"], "inProgress");
        assert_eq!(core.next_sequence, sequence_before_start + 1);
        let started_event: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(started_event["kind"], "stableTurnStarted");
        assert_eq!(started_event["params"]["input"], serde_json::json!([]));
        let status_event: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(status_event["method"], "thread/status/changed");
        assert_eq!(
            status_event["params"]["status"],
            serde_json::json!({"type": "active", "activeFlags": []})
        );
        assert!(core.next_event().is_none());

        let non_eager_read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(non_eager_read["thread"]["status"]["type"], "active");
        assert_eq!(non_eager_read["thread"]["turns"], serde_json::json!([]));

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_eq!(read["thread"]["turns"][0]["items"], serde_json::json!([]));
    }

    #[test]
    fn stable_turn_start_accepts_and_preserves_the_complete_input_and_override_surface() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let params = serde_json::json!({
            "threadId": "00000000-0000-0000-0000-000000000002",
            "clientUserMessageId": "complete-client-input",
            "input": [
                {
                    "type": "text",
                    "text": "Inspect @asset",
                    "text_elements": [{
                        "byteRange": {"start": 8, "end": 14},
                        "placeholder": "asset",
                    }],
                },
                {"type": "image", "detail": "high", "url": "https://example.test/a.png"},
                {"type": "localImage", "detail": "original", "path": "/workspace/a.png"},
                {"type": "audio", "url": "https://example.test/a.wav"},
                {"type": "localAudio", "path": "/workspace/a.wav"},
                {"type": "skill", "name": "inspect", "path": "/workspace/SKILL.md"},
                {"type": "mention", "name": "asset", "path": "/workspace/a.rs"},
            ],
            "cwd": "/workspace/override",
            "approvalPolicy": {
                "granular": {
                    "sandbox_approval": true,
                    "rules": false,
                    "skill_approval": true,
                    "request_permissions": false,
                    "mcp_elicitations": true,
                },
            },
            "approvalsReviewer": "auto_review",
            "sandboxPolicy": {"type": "externalSandbox", "networkAccess": "enabled"},
            "model": "gpt-test",
            "serviceTier": null,
            "effort": "high",
            "summary": "detailed",
            "personality": "pragmatic",
            "outputSchema": {
                "type": "object",
                "properties": {"answer": {"type": "string"}},
                "required": ["answer"],
            },
        });
        let request = serde_json::to_vec(&serde_json::json!({
            "method": "turn/start",
            "params": params.clone(),
        }))
        .unwrap();

        let response: serde_json::Value =
            serde_json::from_slice(&core.request(&request).unwrap()).unwrap();
        let turn_id = response["turn"]["id"].as_str().unwrap();
        let mut expected_params = params.clone();
        expected_params
            .as_object_mut()
            .unwrap()
            .remove("serviceTier");
        expected_params["collaborationMode"] = serde_json::json!({
            "mode": "default",
            "settings": {
                "model": "gpt-test",
                "reasoning_effort": "high",
                "developer_instructions": null,
            },
        });
        assert_eq!(
            core.session.stable_turn_start_params(turn_id),
            Some(&expected_params)
        );

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            read["thread"]["turns"][0]["items"][0]["content"],
            params["input"]
        );
    }

    #[test]
    fn completed_stable_turn_no_longer_projects_the_thread_as_active() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"Finish locally"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["turn"]["id"].as_str().unwrap();
        let complete = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.complete",
            "turnId": turn_id,
            "assistantItem": {
                "id": "00000000-0000-0000-0000-000000000099",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": turn_id,
                "kind": "assistantMessage",
                "text": "Finished",
            },
            "timestamp": 120,
        }))
        .unwrap();
        core.submit(&complete).unwrap();
        while core.next_event().is_some() {}

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["status"]["type"], "idle");
        assert_eq!(read["thread"]["turns"][0]["status"], "completed");
        assert_eq!(read["thread"]["turns"][0]["itemsView"], "summary");
        assert_eq!(
            read["thread"]["turns"][0]["items"][0]["content"][0]["text"],
            "Finish locally"
        );
        assert_eq!(read["thread"]["turns"][0]["items"][1]["text"], "Finished");
    }

    #[test]
    fn stable_turn_start_emits_official_thread_active_status_notification() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        core.request(
            br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
        )
        .unwrap();

        let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        let status = events
            .iter()
            .find(|event| event["method"] == "thread/status/changed")
            .expect("turn/start must publish the official active thread status");
        assert_eq!(
            status,
            &serde_json::json!({
                "method": "thread/status/changed",
                "params": {
                    "threadId": "00000000-0000-0000-0000-000000000002",
                    "status": {
                        "type": "active",
                        "activeFlags": [],
                    },
                },
            })
        );
    }

    #[test]
    fn stable_turn_terminal_commands_emit_official_thread_idle_status_notification() {
        for terminal_kind in ["turn.complete", "turn.fail", "turn.cancel"] {
            let mut core = CodexCore::default();
            seed_thread_directory(&mut core);
            let started: serde_json::Value = serde_json::from_slice(
                &core
                    .request(
                        br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                    )
                    .unwrap(),
            )
            .unwrap();
            let turn_id = started["turn"]["id"].as_str().unwrap().to_owned();
            while core.next_event().is_some() {}

            let terminal = match terminal_kind {
                "turn.complete" => serde_json::json!({
                    "kind": terminal_kind,
                    "turnId": &turn_id,
                    "assistantItem": {
                        "id": "00000000-0000-0000-0000-000000000099",
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "turnId": &turn_id,
                        "kind": "assistantMessage",
                        "text": "Finished",
                    },
                    "timestamp": 120,
                }),
                "turn.fail" => serde_json::json!({
                    "kind": terminal_kind,
                    "turnId": &turn_id,
                    "errorItem": {
                        "id": "00000000-0000-0000-0000-000000000099",
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "turnId": &turn_id,
                        "kind": "error",
                        "text": "Request failed",
                    },
                    "timestamp": 120,
                }),
                "turn.cancel" => serde_json::json!({
                    "kind": terminal_kind,
                    "turnId": &turn_id,
                    "timestamp": 120,
                }),
                _ => unreachable!(),
            };
            core.submit(&serde_json::to_vec(&terminal).unwrap())
                .unwrap();

            let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
                .map(|event| serde_json::from_slice(&event).unwrap())
                .collect();
            let status = events
                .iter()
                .find(|event| event["method"] == "thread/status/changed")
                .unwrap_or_else(|| {
                    panic!("{terminal_kind} must publish the official idle thread status")
                });
            assert_eq!(
                status,
                &serde_json::json!({
                    "method": "thread/status/changed",
                    "params": {
                        "threadId": "00000000-0000-0000-0000-000000000002",
                        "status": {"type": "idle"},
                    },
                }),
                "{terminal_kind}"
            );
        }
    }

    #[test]
    fn stable_compact_lifecycle_emits_official_thread_status_notifications() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"compact","method":"thread/compact/start","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id":"compact","result":{}}));
        let started_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        let compact_started = started_events
            .iter()
            .find(|event| event["kind"] == "stableCompactStarted")
            .expect("compaction should emit a stableCompactStarted event");
        let turn_id = compact_started["turnId"].as_str().unwrap();
        let item_id = compact_started["itemId"].as_str().unwrap();
        assert!(started_events.iter().any(|event| {
            event["method"] == "thread/status/changed"
                && event["params"]["threadId"] == "00000000-0000-0000-0000-000000000002"
                && event["params"]["status"]["type"] == "active"
        }));

        core.submit(
            serde_json::to_vec(&serde_json::json!({
                "kind": "turn.compact-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": turn_id,
                "itemId": item_id,
                "replacementItems": [
                    "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"summary\"}]}"
                ],
                "responseId": "compact-response",
            }))
            .unwrap()
            .as_slice(),
        )
        .unwrap();
        let completed_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert!(completed_events.iter().any(|event| {
            event["method"] == "thread/status/changed"
                && event["params"]["threadId"] == "00000000-0000-0000-0000-000000000002"
                && event["params"]["status"]["type"] == "idle"
        }));
    }

    #[test]
    fn terminal_raw_history_commit_emits_official_thread_idle_status_notification() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["turn"]["id"].as_str().unwrap();
        while core.next_event().is_some() {}

        core.submit(
            serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": turn_id,
                "expectedNextOrder": 0,
                "entries": [],
                "completion": {
                    "responseId": "terminal-response",
                    "endTurn": true,
                },
            }))
            .unwrap()
            .as_slice(),
        )
        .unwrap();

        let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(events[0]["kind"], "turnRawHistoryCommitted");
        assert_eq!(
            events[1],
            serde_json::json!({
                "method": "thread/status/changed",
                "params": {
                    "threadId": "00000000-0000-0000-0000-000000000002",
                    "status": {"type": "idle"},
                },
            })
        );
    }

    #[test]
    fn stable_turn_start_enforces_total_unicode_scalar_boundary_atomically() {
        const MAX_TEXT_CHARACTERS: usize = 1_048_576;

        let mut at_limit = CodexCore::default();
        seed_thread_directory(&mut at_limit);
        let accepted = serde_json::to_vec(&serde_json::json!({
            "method": "turn/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "input": [{"type": "text", "text": "🦀".repeat(MAX_TEXT_CHARACTERS)}],
            },
        }))
        .unwrap();
        assert!(at_limit.request(&accepted).is_ok());

        let mut over_limit = CodexCore::default();
        seed_thread_directory(&mut over_limit);
        let sequence_before_rejection = over_limit.next_sequence;
        let rejected = serde_json::to_vec(&serde_json::json!({
            "method": "turn/start",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "input": [
                    {"type": "text", "text": "🦀".repeat(MAX_TEXT_CHARACTERS)},
                    {"type": "text", "text": "界"},
                ],
            },
        }))
        .unwrap();
        assert_eq!(
            over_limit.request(&rejected),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(over_limit.next_sequence, sequence_before_rejection);
        assert!(over_limit.next_event().is_none());

        let read: serde_json::Value = serde_json::from_slice(
            &over_limit
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"], serde_json::json!([]));
    }

    #[test]
    fn stable_turn_start_rejects_unknown_thread_and_malformed_params_atomically() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let sequence_before_rejections = core.next_sequence;

        for invalid in [
            br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-999999999999","input":[]}}"#.as_slice(),
            br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#.as_slice(),
            br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":7}]}}"#.as_slice(),
        ] {
            assert_eq!(core.request(invalid), Err(CoreError::InvalidArgument));
        }

        assert_eq!(core.next_sequence, sequence_before_rejections);
        assert!(core.next_event().is_none());
        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"], serde_json::json!([]));
    }

    #[test]
    fn stable_turn_start_accepts_released_renderer_null_overrides() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        let params = serde_json::json!({
                "threadId": "00000000-0000-0000-0000-000000000002",
                "clientUserMessageId": "client-message",
                "input": [{"type": "text", "text": "hello", "text_elements": []}],
                "cwd": "/workspace/first",
                "approvalPolicy": "on-request",
                "approvalsReviewer": "auto_review",
                "sandboxPolicy": {
                    "type": "workspaceWrite",
                    "writableRoots": ["/workspace/first"],
                    "networkAccess": true,
                    "excludeTmpdirEnvVar": false,
                    "excludeSlashTmp": false
                },
                "model": null,
                "serviceTier": null,
                "effort": null,
                "summary": "auto",
                "collaborationMode": {"mode": "default", "settings": {"model": "gpt-5.6-sol", "reasoning_effort": "low", "developer_instructions": null}},
                "multiAgentMode": "explicitRequestOnly",
                "personality": "friendly",
                "outputSchema": null,
                "permissions": null,
                "responsesapiClientMetadata": {},
                "attachments": [],
                "runtimeWorkspaceRoots": null
        });
        let request = serde_json::json!({
            "id": "released-null-overrides",
            "method": "turn/start",
            "params": params.clone()
        });
        let result = core.request(serde_json::to_vec(&request).unwrap().as_slice());
        assert!(result.is_ok(), "released null overrides rejected: {result:?}");
    }

    #[test]
    fn sqlite_replays_stable_turn_start_with_the_same_ids_params_and_truthful_view() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Exact raw ID"},"metadata":{"sessionId":"stable-start-durable","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            first.submit(command).unwrap();
        }
        while first.next_event().is_some() {}
        let params = serde_json::json!({
            "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
            "clientUserMessageId": "client-durable",
            "input": [{"type": "text", "text": "persist me", "text_elements": []}],
            "cwd": "/workspace/durable",
            "model": "gpt-test",
            "effort": "high",
        });
        let request = serde_json::to_vec(&serde_json::json!({
            "id": 17,
            "method": "turn/start",
            "params": params.clone(),
        }))
        .unwrap();
        let started: serde_json::Value =
            serde_json::from_slice(&first.request(&request).unwrap()).unwrap();
        let turn_id = started["result"]["turn"]["id"].as_str().unwrap().to_owned();
        let settings_event = first.next_event().unwrap();
        let settings_event_json: serde_json::Value =
            serde_json::from_slice(&settings_event).unwrap();
        assert_eq!(settings_event_json["method"], "thread/settings/updated");
        let expected_params = serde_json::json!({
            "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
            "clientUserMessageId": "client-durable",
            "input": [{"type": "text", "text": "persist me", "text_elements": []}],
            "cwd": "/workspace/durable",
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user",
            "sandboxPolicy": {
                "type": "workspaceWrite",
                "writableRoots": [],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false,
            },
            "model": "gpt-test",
            "effort": "high",
            "summary": "none",
            "collaborationMode": {
                "mode": "default",
                "settings": {
                    "model": "gpt-test",
                    "reasoning_effort": "high",
                    "developer_instructions": null,
                },
            },
            "personality": null,
        });
        let stable_event = first.next_event().unwrap();
        let stable_event_json: serde_json::Value = serde_json::from_slice(&stable_event).unwrap();
        assert_eq!(stable_event_json["kind"], "stableTurnStarted");
        assert_eq!(stable_event_json["turnId"], turn_id);
        assert_eq!(stable_event_json["params"], expected_params);
        let status_event: serde_json::Value =
            serde_json::from_slice(&first.next_event().unwrap()).unwrap();
        assert_eq!(status_event["method"], "thread/status/changed");
        assert_eq!(
            status_event["params"]["status"],
            serde_json::json!({"type": "active", "activeFlags": []})
        );
        assert!(first.next_event().is_none());
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = std::iter::from_fn(|| reopened.next_event()).collect();
        assert_eq!(
            replayed.get(replayed.len().saturating_sub(2)),
            Some(&settings_event)
        );
        assert_eq!(replayed.last(), Some(&stable_event));
        assert_eq!(
            reopened.session.stable_turn_start_params(&turn_id),
            Some(&expected_params)
        );
        let read: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["id"], "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF");
        assert_eq!(read["thread"]["turns"][0]["id"], turn_id);
        assert_eq!(read["thread"]["turns"][0]["itemsView"], "summary");
        assert_eq!(
            read["thread"]["turns"][0]["items"][0]["content"],
            params["input"]
        );
    }

    #[test]
    fn raw_response_history_reopens_with_exact_strings_order_completion_and_usage() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Exact raw ID"},"metadata":{"sessionId":"raw-history-durable","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
        ] {
            first.submit(command).unwrap();
        }
        let started: serde_json::Value = serde_json::from_slice(
            &first
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","input":[{"type":"text","text":"Do not synthesize this as ResponseItem"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["turn"]["id"].as_str().unwrap().to_owned();
        while first.next_event().is_some() {}

        let raw_first = r#"{"type":"message", "role":"assistant","content":[{"type":"output_text","text":"A"}]}"#;
        let raw_second =
            "{\n  \"type\":\"function_call_output\",\"call_id\":\"call-1\",\"output\":\"ok\"\n}";
        let first_commit = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.raw-history.commit",
            "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
            "turnId": turn_id,
            "expectedNextOrder": 0,
            "entries": [{"order": 0, "source": "provider", "itemJson": raw_first}],
            "completion": {
                "responseId": "resp-exact-mid",
                "usage": {"inputTokens": 4, "outputTokens": 2},
                "endTurn": false,
            },
        }))
        .unwrap();
        first.submit(&first_commit).unwrap();
        let first_committed_event = first.next_event().unwrap();
        let first_committed_json: serde_json::Value =
            serde_json::from_slice(&first_committed_event).unwrap();
        assert_eq!(first_committed_json["kind"], "turnRawHistoryCommitted");
        assert_eq!(first_committed_json["entries"][0]["itemJson"], raw_first);
        assert_eq!(
            first_committed_json["completion"]["responseId"],
            "resp-exact-mid"
        );
        assert_eq!(first_committed_json["completion"]["endTurn"], false);
        assert!(
            first.next_event().is_none(),
            "non-terminal raw-history commit must not publish an idle status"
        );

        let final_commit = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.raw-history.commit",
            "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
            "turnId": turn_id,
            "expectedNextOrder": 1,
            "entries": [{"order": 1, "source": "localTool", "itemJson": raw_second}],
            "completion": {
                "responseId": "resp-exact-final",
                "usage": {"inputTokens": 11, "outputTokens": 7},
                "endTurn": true,
            },
        }))
        .unwrap();
        first.submit(&final_commit).unwrap();
        let committed_event = first.next_event().unwrap();
        let committed_json: serde_json::Value = serde_json::from_slice(&committed_event).unwrap();
        assert_eq!(committed_json["kind"], "turnRawHistoryCommitted");
        assert_eq!(committed_json["entries"][0]["itemJson"], raw_second);
        assert_eq!(
            committed_json["completion"]["responseId"],
            "resp-exact-final"
        );
        assert_eq!(
            committed_json["completion"]["usage"],
            serde_json::json!({"inputTokens": 11, "outputTokens": 7})
        );
        let status_event: serde_json::Value =
            serde_json::from_slice(&first.next_event().unwrap()).unwrap();
        assert_eq!(
            status_event,
            serde_json::json!({
                "method": "thread/status/changed",
                "params": {
                    "threadId": "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF",
                    "status": {"type": "idle"},
                },
            })
        );
        assert!(first.next_event().is_none());

        let prior_before_restart: serde_json::Value = serde_json::from_slice(
            &first
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let prior_items = prior_before_restart["items"].as_array().unwrap();
        let user_item: serde_json::Value =
            serde_json::from_str(prior_items[0].as_str().unwrap()).unwrap();
        assert_eq!(user_item["type"], "message");
        assert_eq!(user_item["role"], "user");
        assert_eq!(
            user_item["content"],
            serde_json::json!([{
                "type": "input_text",
                "text": "Do not synthesize this as ResponseItem",
            }])
        );
        assert_eq!(prior_items.len(), 3);
        assert_eq!(prior_items[1], raw_first);
        assert_eq!(prior_items[2], raw_second);
        assert_eq!(prior_before_restart["completeness"], "complete");
        assert_eq!(prior_before_restart["throughTurnId"], turn_id);
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: Vec<Vec<u8>> = std::iter::from_fn(|| reopened.next_event()).collect();
        let replayed_raw_commits: Vec<Vec<u8>> = replayed
            .into_iter()
            .filter(|event| {
                serde_json::from_slice::<serde_json::Value>(event)
                    .is_ok_and(|event| event["kind"] == "turnRawHistoryCommitted")
            })
            .collect();
        assert_eq!(
            replayed_raw_commits,
            vec![first_committed_event, committed_event]
        );
        let prior: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(prior, prior_before_restart);
        let read: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"][0]["itemsView"], "summary");
        assert_eq!(read["thread"]["turns"][0]["status"], "completed");
        let restored_items = read["thread"]["turns"][0]["items"].as_array().unwrap();
        assert!(
            restored_items
                .iter()
                .any(|item| { item["type"] == "agentMessage" && item["text"] == "A" })
        );

        let resumed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"id":"resume-after-reopen","method":"thread/resume","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","model":"gpt-5.6-sol","modelProvider":"openai","approvalPolicy":"never","approvalsReviewer":"user","sandbox":"danger-full-access"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let resumed_items = resumed["result"]["thread"]["turns"][0]["items"]
            .as_array()
            .unwrap();
        assert!(
            resumed_items
                .iter()
                .any(|item| { item["type"] == "agentMessage" && item["text"] == "A" }),
            "thread/resume must restore the same provider assistant message as thread/read"
        );
    }

    #[test]
    fn raw_history_rejections_leave_sequence_state_and_sqlite_unchanged() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Atomic raw history"}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let first_turn: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let first_turn_id = first_turn["turn"]["id"].as_str().unwrap().to_owned();
        let second_turn: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let second_turn_id = second_turn["turn"]["id"].as_str().unwrap().to_owned();
        let first_commit = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.raw-history.commit",
            "threadId": "00000000-0000-0000-0000-000000000002",
            "turnId": first_turn_id,
            "expectedNextOrder": 0,
            "entries": [{"order": 0, "source": "provider", "itemJson": "{\"type\":\"message\"}"}],
            "completion": {"responseId": "duplicate-response", "endTurn": false},
        }))
        .unwrap();
        core.submit(&first_commit).unwrap();
        while core.next_event().is_some() {}
        let next_sequence = core.next_sequence;
        let batch_count: i64 = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
            .unwrap();

        let invalid = [
            serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": first_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": "{\"type\":\"message\"}"}],
            }),
            serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": second_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 1, "source": "provider", "itemJson": "{\"type\":\"message\"}"}],
            }),
            serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": second_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": "{"}],
            }),
            serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": first_turn_id,
                "expectedNextOrder": 1,
                "entries": [],
                "completion": {"responseId": "duplicate-response", "endTurn": false},
            }),
        ];
        for command in invalid {
            assert_eq!(
                core.submit(&serde_json::to_vec(&command).unwrap()),
                Err(CoreError::InvalidArgument)
            );
            assert_eq!(core.next_sequence, next_sequence);
            assert!(core.next_event().is_none());
            let count: i64 = rusqlite::Connection::open(&database)
                .unwrap()
                .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
                .unwrap();
            assert_eq!(count, batch_count);
        }

        let valid_second = serde_json::to_vec(&serde_json::json!({
            "kind": "turn.raw-history.commit",
            "threadId": "00000000-0000-0000-0000-000000000002",
            "turnId": second_turn_id,
            "expectedNextOrder": 0,
            "entries": [{"order": 0, "source": "localTool", "itemJson": "{\"type\":\"function_call_output\"}"}],
            "completion": {"responseId": "unique-response", "endTurn": true},
        }))
        .unwrap();
        core.submit(&valid_second).unwrap();
        assert_eq!(core.next_sequence, next_sequence + 1);
    }

    #[test]
    fn prior_input_items_honors_before_turn_and_reports_legacy_fidelity() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Legacy raw history"},"metadata":{"sessionId":"legacy-raw-history","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"legacy one"},"timestamp":101}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"legacy answer one"},"timestamp":102}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"legacy two"},"timestamp":103}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000020","assistantItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000020","kind":"assistantMessage","text":"legacy answer two"},"timestamp":104}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let unavailable: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","beforeTurnId":"00000000-0000-0000-0000-000000000020"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            unavailable["threadId"],
            "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
        );
        assert!(unavailable["throughTurnId"].is_null());
        assert_eq!(unavailable["items"], serde_json::json!([]));
        assert_eq!(unavailable["completeness"], "legacyUnavailable");

        core.submit(
            br#"{"kind":"turn.raw-history.commit","threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","turnId":"00000000-0000-0000-0000-000000000010","expectedNextOrder":0,"entries":[{"order":0,"source":"provider","itemJson":"{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}"}],"completion":{"responseId":"legacy-backfill","endTurn":true}}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        let partial: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            partial["throughTurnId"],
            "00000000-0000-0000-0000-000000000010"
        );
        assert_eq!(
            partial["items"],
            serde_json::json!([r#"{"type":"message","role":"assistant","content":[]}"#])
        );
        assert_eq!(partial["completeness"], "partialLegacy");

        let empty_prefix: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","beforeTurnId":"00000000-0000-0000-0000-000000000010"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert!(empty_prefix["throughTurnId"].is_null());
        assert_eq!(empty_prefix["items"], serde_json::json!([]));
        assert_eq!(empty_prefix["completeness"], "complete");

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        while reopened.next_event().is_some() {}
        let replayed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(replayed, partial);
        let read: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert!(
            read["thread"]["turns"]
                .as_array()
                .unwrap()
                .iter()
                .all(|turn| turn["itemsView"] == "summary")
        );
    }

    #[test]
    fn prior_before_current_excludes_failed_and_in_progress_partial_raw_history() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let older: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"older complete"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let older_turn_id = older["turn"]["id"].as_str().unwrap().to_owned();
        let older_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"older exact"}]}"#;
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": older_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": older_raw}],
                "completion": {"responseId": "shared-across-turns", "endTurn": true},
            }))
            .unwrap(),
        )
        .unwrap();

        let failed: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"failed partial"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let failed_turn_id = failed["turn"]["id"].as_str().unwrap().to_owned();
        let failed_partial_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"exclude failed partial"}]}"#;
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": failed_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": failed_partial_raw}],
                "completion": {"responseId": "shared-across-turns", "endTurn": false},
            }))
            .unwrap(),
        )
        .unwrap();
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.fail",
                "turnId": failed_turn_id,
                "errorItem": {
                    "id": "00000000-0000-0000-0000-000000000099",
                    "threadId": "00000000-0000-0000-0000-000000000002",
                    "turnId": failed_turn_id,
                    "kind": "error",
                    "text": "provider failed after partial response",
                },
                "timestamp": 120,
            }))
            .unwrap(),
        )
        .unwrap();

        let current: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"current in progress"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let current_turn_id = current["turn"]["id"].as_str().unwrap().to_owned();
        let current_partial_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"exclude current partial"}]}"#;
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": current_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": current_partial_raw}],
                "completion": {"responseId": "shared-across-turns", "endTurn": false},
            }))
            .unwrap(),
        )
        .unwrap();
        while core.next_event().is_some() {}

        let query = serde_json::to_vec(&serde_json::json!({
            "method": "thread/prior-input-items",
            "params": {
                "threadId": "00000000-0000-0000-0000-000000000002",
                "beforeTurnId": current_turn_id,
            },
        }))
        .unwrap();
        let prior: serde_json::Value =
            serde_json::from_slice(&core.request(&query).unwrap()).unwrap();
        assert_eq!(prior["throughTurnId"], older_turn_id);
        assert_eq!(prior["completeness"], "partialLegacy");
        assert_eq!(
            prior["items"],
            serde_json::json!([
                r#"{"type":"message","role":"user","content":[{"type":"input_text","text":"older complete"}]}"#,
                older_raw,
            ])
        );
        let encoded = serde_json::to_string(&prior).unwrap();
        assert!(!encoded.contains(failed_partial_raw));
        assert!(!encoded.contains(current_partial_raw));

        let all_prior: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(all_prior, prior);
    }

    #[test]
    fn prior_excludes_failed_and_cancelled_turns_even_after_late_end_turn_commit() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Late raw completion"}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"completed legacy"}}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"completed coarse answer"}}"#.as_slice(),
            br#"{"kind":"turn.raw-history.commit","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","expectedNextOrder":0,"entries":[{"order":0,"source":"provider","itemJson":"{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"completed exact\"}]}"}],"completion":{"responseId":"late-response","endTurn":true}}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        let completed_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"completed exact"}]}"#;

        let failed: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"exclude failed user"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let failed_turn_id = failed["turn"]["id"].as_str().unwrap().to_owned();
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.fail",
                "turnId": failed_turn_id,
                "errorItem": {
                    "id": "00000000-0000-0000-0000-000000000090",
                    "threadId": "00000000-0000-0000-0000-000000000002",
                    "turnId": failed_turn_id,
                    "kind": "error",
                    "text": "failed before late completion",
                },
            }))
            .unwrap(),
        )
        .unwrap();
        let failed_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"exclude failed raw"}]}"#;
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": failed_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": failed_raw}],
                "completion": {"responseId": "late-response", "endTurn": true},
            }))
            .unwrap(),
        )
        .unwrap();

        let cancelled: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"turn/start","params":{"threadId":"00000000-0000-0000-0000-000000000002","input":[{"type":"text","text":"exclude cancelled user"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let cancelled_turn_id = cancelled["turn"]["id"].as_str().unwrap().to_owned();
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.cancel",
                "turnId": cancelled_turn_id,
            }))
            .unwrap(),
        )
        .unwrap();
        let cancelled_raw = r#"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"exclude cancelled raw"}]}"#;
        core.submit(
            &serde_json::to_vec(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": "00000000-0000-0000-0000-000000000002",
                "turnId": cancelled_turn_id,
                "expectedNextOrder": 0,
                "entries": [{"order": 0, "source": "provider", "itemJson": cancelled_raw}],
                "completion": {"responseId": "late-response", "endTurn": true},
            }))
            .unwrap(),
        )
        .unwrap();
        while core.next_event().is_some() {}

        let prior: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/prior-input-items","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            prior["throughTurnId"],
            "00000000-0000-0000-0000-000000000010"
        );
        assert_eq!(prior["items"], serde_json::json!([completed_raw]));
        assert_eq!(prior["completeness"], "partialLegacy");
        let encoded = serde_json::to_string(&prior).unwrap();
        for excluded in [
            "exclude failed user",
            failed_raw,
            "exclude cancelled user",
            cancelled_raw,
        ] {
            assert!(!encoded.contains(excluded));
        }
    }

    #[test]
    fn thread_list_uses_official_defaults_filters_and_opaque_pagination() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let first_page: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/list","params":{"limit":1}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(first_page["data"].as_array().unwrap().len(), 1);
        assert_eq!(
            first_page["data"][0]["id"],
            "00000000-0000-0000-0000-000000000003"
        );
        assert_eq!(first_page["data"][0]["sessionId"], "session-tree");
        assert_eq!(first_page["data"][0]["name"], "Second task");
        assert_eq!(first_page["data"][0]["turns"], serde_json::json!([]));
        let next_cursor = first_page["nextCursor"]
            .as_str()
            .expect("a second interactive thread remains");
        assert!(next_cursor.starts_with("ct1."));
        assert!(
            first_page["backwardsCursor"]
                .as_str()
                .is_some_and(|cursor| cursor.starts_with("ct1."))
        );

        let next_request = serde_json::json!({
            "method": "thread/list",
            "params": {"limit": 1, "cursor": next_cursor},
        });
        let second_page: serde_json::Value = serde_json::from_slice(
            &core
                .request(&serde_json::to_vec(&next_request).unwrap())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            second_page["data"][0]["id"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert!(second_page["nextCursor"].is_null());

        let archived: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/list","params":{"archived":true,"modelProviders":[],"sourceKinds":["exec"]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(archived["data"].as_array().unwrap().len(), 1);
        assert_eq!(
            archived["data"][0]["id"],
            "00000000-0000-0000-0000-000000000004"
        );
        assert_eq!(archived["data"][0]["modelProvider"], "other-provider");
    }

    #[test]
    fn thread_read_returns_metadata_without_eager_turns_and_reads_archived_threads() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000004"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response["thread"]["id"],
            "00000000-0000-0000-0000-000000000004"
        );
        assert_eq!(response["thread"]["cwd"], "/workspace/third");
        assert_eq!(response["thread"]["source"], "exec");
        assert_eq!(response["thread"]["turns"], serde_json::json!([]));
        assert_eq!(
            core.request(
                br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-999999999999"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn thread_directory_tracks_renames_forks_and_deletes() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.set-name","threadId":"00000000-0000-0000-0000-000000000002","name":"Renamed task"}"#,
        )
        .unwrap();

        let renamed: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(renamed["thread"]["name"], "Renamed task");

        core.submit(
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000005","title":"Forked task","lastTurnId":null,"turnIdMap":{},"itemIdMap":{},"timestamp":1722345700}"#,
        )
        .unwrap();
        let forked: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000005"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(forked["thread"]["name"], "Forked task");
        assert_eq!(
            forked["thread"]["forkedFromId"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(
            forked["thread"]["sessionId"],
            "00000000-0000-0000-0000-000000000005"
        );
        assert_eq!(forked["thread"]["createdAt"], 1_722_345_700_i64);
        assert_eq!(forked["thread"]["cwd"], "/workspace/first");
        assert_eq!(forked["thread"]["modelProvider"], "openai");
        assert_eq!(forked["thread"]["source"], "vscode");
        assert_eq!(forked["thread"]["preview"], "");

        core.submit(
            br#"{"kind":"thread.delete","threadId":"00000000-0000-0000-0000-000000000005"}"#,
        )
        .unwrap();
        assert_eq!(
            core.request(
                br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000005"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn official_fork_preview_comes_from_the_first_user_item_in_the_cutoff_history() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Preview task"},"metadata":{"sessionId":"00000000-0000-0000-0000-000000000002","preview":"","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":100,"recencyAt":100,"path":null,"cwd":"/workspace/preview","cliVersion":"0.146.0-alpha.3.1","source":"appServer","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"  First user request  "},"timestamp":101}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"First answer"},"timestamp":102}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"Second user request"},"timestamp":103}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000020","assistantItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"assistantMessage","text":"Second answer"},"timestamp":104}"#.as_slice(),
            br#"{"kind":"thread.fork","threadId":"00000000-0000-0000-0000-000000000002","newThreadId":"00000000-0000-0000-0000-000000000030","title":"Preview task (fork)","lastTurnId":"00000000-0000-0000-0000-000000000010","turnIdMap":{"00000000-0000-0000-0000-000000000010":"00000000-0000-0000-0000-000000000031"},"itemIdMap":{"00000000-0000-0000-0000-000000000011":"00000000-0000-0000-0000-000000000032","00000000-0000-0000-0000-000000000012":"00000000-0000-0000-0000-000000000033"},"timestamp":105}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }

        let source: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(source["thread"]["preview"], "First user request");

        let fork: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000030","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(fork["thread"]["preview"], "First user request");
        assert_eq!(fork["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_eq!(
            fork["thread"]["turns"][0]["items"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn thread_metadata_update_applies_git_tri_state_to_archived_threads() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let updated: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":{"sha":"  def456  ","branch":null}}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(updated["thread"]["gitInfo"]["sha"], "def456");
        assert!(updated["thread"]["gitInfo"]["branch"].is_null());
        assert!(updated["thread"]["gitInfo"]["originUrl"].is_null());

        let read_back: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000004"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read_back["thread"]["gitInfo"]["sha"], "def456");

        for invalid in [
            br#"{"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004"}}"#.as_slice(),
            br#"{"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":null}}"#.as_slice(),
            br#"{"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":{}}}"#.as_slice(),
            br#"{"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":{"branch":" \n "}}}"#.as_slice(),
        ] {
            assert_eq!(core.request(invalid), Err(CoreError::InvalidArgument));
        }
    }

    #[test]
    fn thread_search_finds_visible_conversation_content_case_insensitively() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        for command in [
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"Please Inspect the Protocol Bridge now"},"timestamp":120}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"The bridge is ready."},"timestamp":121}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/search","params":{"searchTerm":"protocol bridge"}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["data"].as_array().unwrap().len(), 1);
        assert_eq!(
            response["data"][0]["thread"]["id"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert!(
            response["data"][0]["snippet"]
                .as_str()
                .unwrap()
                .contains("Protocol Bridge")
        );
        assert!(response["nextCursor"].is_null());
        assert_eq!(
            core.request(br#"{"method":"thread/search","params":{"searchTerm":" \n "}}"#),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn thread_requests_with_ids_return_official_success_envelopes() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);

        let list: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"list-1","method":"thread/list","params":{"limit":1}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(list["id"], "list-1");
        assert_eq!(list["result"]["data"].as_array().unwrap().len(), 1);
        assert!(list.get("data").is_none());

        let metadata: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":7,"method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":{"branch":"main"}}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(metadata["id"], 7);
        assert_eq!(metadata["result"]["thread"]["gitInfo"]["branch"], "main");
        assert_eq!(
            core.request(br#"{"id":true,"method":"thread/list","params":{}}"#),
            Err(CoreError::InvalidJson)
        );
    }

    #[test]
    fn thread_queries_are_read_only_and_metadata_updates_replay_from_storage() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);

        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut first);
        let sequence_before_queries = first.next_sequence;

        for request in [
            br#"{"id":"list","method":"thread/list","params":{"limit":1}}"#.as_slice(),
            br#"{"id":"read","method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#.as_slice(),
            br#"{"id":"search","method":"thread/search","params":{"searchTerm":"missing"}}"#
                .as_slice(),
        ] {
            first.request(request).unwrap();
        }
        assert_eq!(first.next_sequence, sequence_before_queries);
        assert!(first.events.is_empty());

        first
            .request(
                br#"{"id":"metadata","method":"thread/metadata/update","params":{"threadId":"00000000-0000-0000-0000-000000000004","gitInfo":{"branch":"release"},"sectionId":"01984de2-8f74-7c91-a3b2-5c5e937cf318"}}"#,
            )
            .unwrap();
        assert_eq!(first.next_sequence, sequence_before_queries + 1);
        let expected_metadata_event = first.next_event().unwrap();
        let decoded_event: serde_json::Value =
            serde_json::from_slice(&expected_metadata_event).unwrap();
        assert_eq!(decoded_event["kind"], "threadMetadataChanged");
        assert_eq!(
            decoded_event["threadId"],
            "00000000-0000-0000-0000-000000000004"
        );
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let persisted: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000004"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(persisted["thread"]["gitInfo"]["branch"], "release");
        assert_eq!(
            persisted["thread"]["section"],
            serde_json::json!({
                "id": "01984de2-8f74-7c91-a3b2-5c5e937cf318",
                "name": "Pinned"
            })
        );

        let replay_count_before_queries = reopened.events.len();
        let sequence_after_replay = reopened.next_sequence;
        reopened
            .request(br#"{"method":"thread/list","params":{"archived":true}}"#)
            .unwrap();
        reopened
            .request(
                br#"{"method":"thread/search","params":{"searchTerm":"missing","archived":true}}"#,
            )
            .unwrap();
        assert_eq!(reopened.events.len(), replay_count_before_queries);
        assert_eq!(reopened.next_sequence, sequence_after_replay);

        let replayed: Vec<Vec<u8>> = std::iter::from_fn(|| reopened.next_event()).collect();
        assert_eq!(replayed.last(), Some(&expected_metadata_event));
    }

    #[test]
    fn thread_section_list_uses_persisted_registry_without_mutating_events() {
        let mut unopened = CodexCore::default();
        assert_eq!(
            unopened.request(
                br#"{"id":"sections","method":"threadSection/list","params":{"limit":1}}"#
            ),
            Err(CoreError::UnsupportedCommand)
        );

        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let mut core = CodexCore::default();
        core.submit(storage_open_command(&database, &snapshots).as_bytes())
            .unwrap();
        let sequence_before = core.next_sequence;
        let event_count_before = core.events.len();

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"sections","method":"threadSection/list","params":{"limit":0}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["id"], "sections");
        assert_eq!(
            response["result"]["data"],
            serde_json::json!([{
                "id": "01984de2-8f74-7c91-a3b2-5c5e937cf318",
                "name": "Pinned"
            }])
        );
        assert!(response["result"]["nextCursor"].is_null());
        assert_eq!(core.next_sequence, sequence_before);
        assert_eq!(core.events.len(), event_count_before);

        let after_cursor: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"threadSection/list","params":{"cursor":"01984de2-8f74-7c91-a3b2-5c5e937cf318","limit":1000}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(after_cursor["data"], serde_json::json!([]));
        assert!(after_cursor["nextCursor"].is_null());
    }

    #[test]
    fn stable_thread_rollback_drops_trailing_completed_turns_and_is_atomic() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        for command in [
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"First request"},"timestamp":120}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"First response"},"timestamp":121}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"Second request"},"timestamp":122}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000020","assistantItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"assistantMessage","text":"Second response"},"timestamp":123}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"rollback","method":"thread/rollback","params":{"threadId":"00000000-0000-0000-0000-000000000002","numTurns":1}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["id"], "rollback");
        let turns = response["result"]["thread"]["turns"].as_array().unwrap();
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0]["id"], "00000000-0000-0000-0000-000000000010");
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadRolledBack");
        assert_eq!(
            event["removedTurnIds"],
            serde_json::json!(["00000000-0000-0000-0000-000000000020"])
        );

        let sequence = core.next_sequence;
        assert_eq!(
            core.request(
                br#"{"method":"thread/rollback","params":{"threadId":"00000000-0000-0000-0000-000000000002","numTurns":2}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn stable_thread_revert_removes_the_named_turn_and_later_completed_history() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        for command in [
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"First request"},"timestamp":120}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"First response"},"timestamp":121}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"Second request"},"timestamp":122}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000020","assistantItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"assistantMessage","text":"Second response"},"timestamp":123}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        core.submit(
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000030","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000031","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000030","kind":"userMessage","text":"Third request"},"timestamp":124}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        let sequence_before_running_revert = core.next_sequence;
        assert_eq!(
            core.request(
                br#"{"method":"thread/revert","params":{"threadId":"00000000-0000-0000-0000-000000000002","beforeTurnId":"00000000-0000-0000-0000-000000000020"}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence_before_running_revert);
        assert!(core.next_event().is_none());
        core.submit(
            br#"{"kind":"turn.cancel","turnId":"00000000-0000-0000-0000-000000000030","timestamp":125}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"revert","method":"thread/revert","params":{"threadId":"00000000-0000-0000-0000-000000000002","beforeTurnId":"00000000-0000-0000-0000-000000000020"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["id"], "revert");
        assert_eq!(
            response["result"]["thread"]["id"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(response["result"]["thread"]["turns"], serde_json::json!([]));
        let decode_cursor = |cursor: &serde_json::Value| -> serde_json::Value {
            let encoded = cursor.as_str().expect("opaque cursor");
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .unwrap();
            serde_json::from_slice(&bytes).unwrap()
        };
        let turns_cursor = decode_cursor(&response["result"]["turnsBackwardsCursor"]);
        assert_eq!(turns_cursor["kind"], "turn");
        assert_eq!(
            turns_cursor["threadID"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(
            turns_cursor["anchorID"],
            "00000000-0000-0000-0000-000000000010"
        );
        assert_eq!(turns_cursor["includeAnchor"], true);
        let items_cursor = decode_cursor(&response["result"]["itemsBackwardsCursor"]);
        assert_eq!(items_cursor["kind"], "item");
        assert_eq!(
            items_cursor["threadID"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(
            items_cursor["anchorID"],
            "00000000-0000-0000-0000-000000000012"
        );
        assert_eq!(items_cursor["includeAnchor"], true);

        let turns: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(turns["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_eq!(
            turns["thread"]["turns"][0]["id"],
            "00000000-0000-0000-0000-000000000010"
        );
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadReverted");
        assert_eq!(
            event["beforeTurnId"],
            "00000000-0000-0000-0000-000000000020"
        );
        assert_eq!(
            event["removedTurnIds"],
            serde_json::json!([
                "00000000-0000-0000-0000-000000000020",
                "00000000-0000-0000-0000-000000000030"
            ])
        );

        let sequence = core.next_sequence;
        for request in [
            br#"{"method":"thread/revert","params":{"threadId":"00000000-0000-0000-0000-000000000002","beforeTurnId":"00000000-0000-0000-0000-000000000999"}}"#.as_slice(),
            br#"{"method":"thread/revert","params":{"threadId":"00000000-0000-0000-0000-000000000003","beforeTurnId":"00000000-0000-0000-0000-000000000010"}}"#.as_slice(),
        ] {
            assert_eq!(core.request(request), Err(CoreError::InvalidArgument));
            assert_eq!(core.next_sequence, sequence);
            assert!(core.next_event().is_none());
        }
    }

    #[test]
    fn stable_thread_fork_deep_copies_through_turn_and_persists_overrides_atomically() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut core);
        for command in [
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/original","model":"gpt-5.4","effort":"high","approvalPolicy":"on-request","approvalsReviewer":"auto_review","sandboxPolicy":{"type":"readOnly","networkAccess":false},"serviceTier":"priority"}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"First request"},"timestamp":120}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"First response"},"timestamp":121}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"Second request"},"timestamp":122}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000020","assistantItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"assistantMessage","text":"Second response"},"timestamp":123}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let sequence_before_invalid = core.next_sequence;
        assert_eq!(
            core.request(
                br#"{"method":"thread/fork","params":{"threadId":"00000000-0000-0000-0000-000000000002","baseInstructions":"dropped runtime override"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence_before_invalid);
        assert!(core.next_event().is_none());

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"fork","method":"thread/fork","params":{"threadId":"00000000-0000-0000-0000-000000000002","lastTurnId":"00000000-0000-0000-0000-000000000010","model":"gpt-5.5","modelProvider":"custom-provider","serviceTier":null,"cwd":"/workspace/fork","approvalPolicy":"never","approvalsReviewer":"user","sandbox":"danger-full-access","ephemeral":true,"threadSource":"automation"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["id"], "fork");
        let result = &response["result"];
        let forked_id = result["thread"]["id"].as_str().unwrap().to_owned();
        assert_ne!(forked_id, "00000000-0000-0000-0000-000000000002");
        assert_eq!(result["thread"]["sessionId"], forked_id.as_str());
        assert_eq!(
            result["thread"]["forkedFromId"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(result["thread"]["ephemeral"], true);
        assert_eq!(result["thread"]["threadSource"], "automation");
        assert_eq!(result["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_ne!(
            result["thread"]["turns"][0]["id"],
            "00000000-0000-0000-0000-000000000010"
        );
        assert_eq!(
            result["thread"]["turns"][0]["items"][0]["content"][0]["text"],
            "First request"
        );
        assert_eq!(
            result["thread"]["turns"][0]["items"][1]["text"],
            "First response"
        );
        assert_eq!(result["model"], "gpt-5.5");
        assert_eq!(result["modelProvider"], "custom-provider");
        assert!(result["serviceTier"].is_null());
        assert_eq!(result["cwd"], "/workspace/fork");
        assert_eq!(result["approvalPolicy"], "never");
        assert_eq!(result["approvalsReviewer"], "user");
        assert_eq!(result["sandbox"]["type"], "dangerFullAccess");
        assert!(result["reasoningEffort"].is_null());

        let persisted: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/resume",
                        "params": {"threadId": &forked_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(persisted["model"], "gpt-5.5");
        assert_eq!(persisted["cwd"], "/workspace/fork");
        assert_eq!(persisted["sandbox"]["type"], "dangerFullAccess");

        let events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(events[0]["kind"], "threadUpserted");
        assert!(
            events
                .iter()
                .any(|event| event["kind"] == "threadSettingsUpdated")
        );
        assert_eq!(
            events
                .iter()
                .filter(|event| event["kind"] == "turnStarted")
                .count(),
            1
        );
        assert_eq!(
            events
                .iter()
                .filter(|event| event["kind"] == "itemAppended")
                .count(),
            2
        );

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/resume",
                        "params": {"threadId": &forked_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            replayed["thread"]["forkedFromId"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(replayed["thread"]["turns"].as_array().unwrap().len(), 1);
        assert_eq!(replayed["model"], "gpt-5.5");
        assert_eq!(replayed["cwd"], "/workspace/fork");
    }

    #[test]
    fn stable_thread_fork_uses_path_hides_only_the_response_and_inherits_side_chat_settings() {
        let mut core = CodexCore::default();
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Path source"},"metadata":{"sessionId":"path-source","preview":"Source preview","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":110,"recencyAt":110,"path":"/workspace/sessions/source-rollout.jsonl","cwd":"/workspace/source","cliVersion":"0.146.0-alpha.3.1","source":"vscode","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000003","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Distractor"},"metadata":{"sessionId":"distractor","preview":"Distractor preview","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":210,"recencyAt":210,"path":"/workspace/sessions/distractor-rollout.jsonl","cwd":"/workspace/distractor","cliVersion":"0.146.0-alpha.3.1","source":"vscode","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/source","model":"gpt-5.4","effort":"low","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly","networkAccess":false}}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000010","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000011","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"userMessage","text":"Completed request"},"timestamp":120}"#.as_slice(),
            br#"{"kind":"turn.complete","turnId":"00000000-0000-0000-0000-000000000010","assistantItem":{"id":"00000000-0000-0000-0000-000000000012","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000010","kind":"assistantMessage","text":"Completed response"},"timestamp":121}"#.as_slice(),
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000020","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000021","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"userMessage","text":"Failed request"},"timestamp":122}"#.as_slice(),
            br#"{"kind":"turn.fail","turnId":"00000000-0000-0000-0000-000000000020","errorItem":{"id":"00000000-0000-0000-0000-000000000022","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000020","kind":"error","text":"Provider failed during side chat"},"timestamp":123}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"fork-by-path","method":"thread/fork","params":{"threadId":"00000000-0000-0000-0000-000000000003","path":"/workspace/sessions/source-rollout.jsonl","excludeTurns":true,"model":"gpt-5.6-sol","modelProvider":"openai","config":{"model_reasoning_effort":"high"},"developerInstructions":"Keep the side conversation isolated."}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let result = &response["result"];
        let forked_id = result["thread"]["id"].as_str().unwrap().to_owned();
        assert_eq!(response["id"], "fork-by-path");
        assert_eq!(result["thread"]["name"], "Path source");
        assert_eq!(
            result["thread"]["forkedFromId"],
            "00000000-0000-0000-0000-000000000002"
        );
        assert!(result["thread"]["turns"].as_array().unwrap().is_empty());

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/read",
                        "params": {"threadId": &forked_id, "includeTurns": true},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let copied_turns = read["thread"]["turns"].as_array().unwrap();
        assert_eq!(copied_turns.len(), 2);
        assert_eq!(
            copied_turns[0]["items"][0]["content"][0]["text"],
            "Completed request"
        );
        assert_eq!(copied_turns[1]["status"], "failed");
        assert_eq!(
            copied_turns[1]["error"]["message"],
            "Provider failed during side chat"
        );

        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "turn/start",
                        "params": {"threadId": &forked_id, "input": []},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = started["turn"]["id"].as_str().unwrap();
        let effective = core.session.stable_turn_start_params(turn_id).unwrap();
        assert_eq!(effective["model"], "gpt-5.6-sol");
        assert_eq!(effective["effort"], "high");
        assert_eq!(
            effective["collaborationMode"]["settings"]["developer_instructions"],
            "Keep the side conversation isolated."
        );

        assert_eq!(
            core.request(
                br#"{"method":"thread/resume","params":{"threadId":"00000000-0000-0000-0000-000000000002","developerInstructions":"Resume must still reject this."}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn stable_thread_fork_accepts_full_renderer_codex_config() {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/first","model":"gpt-5.6-sol","effort":"low","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[],"networkAccess":false,"excludeTmpdirEnvVar":false,"excludeSlashTmp":false},"summary":"none","personality":"friendly","multiAgentMode":"explicitRequestOnly"}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"side-chat","method":"thread/fork","params":{"threadId":"00000000-0000-0000-0000-000000000002","path":null,"cwd":"/workspace/first","threadSource":"user","model":"gpt-5.6-sol","config":{"model_reasoning_effort":"low","multi_agent_mode":"explicitRequestOnly","personality":"friendly","summary":"detailed"},"developerInstructions":"Keep the side conversation isolated.","excludeTurns":true}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "side-chat");
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["reasoningEffort"], "low");
        assert_eq!(
            response["result"]["thread"]["forkedFromId"],
            "00000000-0000-0000-0000-000000000002"
        );
    }

    #[test]
    fn stable_thread_fork_empty_or_null_path_falls_back_and_validates_exclude_turns() {
        for path in [serde_json::Value::Null, serde_json::json!("")] {
            let mut core = CodexCore::default();
            seed_thread_directory(&mut core);
            core.submit(
                br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/first","model":"gpt-5.4","effort":"low","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly","networkAccess":false}}"#,
            )
            .unwrap();
            while core.next_event().is_some() {}

            let response: serde_json::Value = serde_json::from_slice(
                &core
                    .request(
                        serde_json::to_string(&serde_json::json!({
                            "method": "thread/fork",
                            "params": {
                                "threadId": "00000000-0000-0000-0000-000000000002",
                                "path": path,
                                "excludeTurns": false,
                            },
                        }))
                        .unwrap()
                        .as_bytes(),
                    )
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(
                response["thread"]["forkedFromId"],
                "00000000-0000-0000-0000-000000000002"
            );
        }

        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"thread.settings-update","threadId":"00000000-0000-0000-0000-000000000002","cwd":"/workspace/first","model":"gpt-5.4","effort":"low","approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"readOnly","networkAccess":false}}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        assert_eq!(
            core.request(
                br#"{"method":"thread/fork","params":{"threadId":"00000000-0000-0000-0000-000000000002","excludeTurns":"true"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    #[test]
    fn stable_thread_start_accepts_complete_released_desktop_params() {
        let mut core = CodexCore::default();
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"released-full","method":"thread/start","params":{"model":"gpt-5.6-sol","modelProvider":"openai","allowProviderModelFallback":true,"serviceTier":"priority","cwd":"/workspace/project","runtimeWorkspaceRoots":["/workspace/project","/workspace/shared"],"approvalPolicy":"never","approvalsReviewer":"user","permissions":":workspace","config":{"ambient-suggestions-enabled":true,"features":{"thread_tools":true},"model_reasoning_effort":"high"},"serviceName":"desktop","baseInstructions":"Base instructions","developerInstructions":"Developer instructions","personality":"pragmatic","mode":"default","multiAgentMode":"explicitRequestOnly","threadStartKind":"default","ephemeral":true,"historyMode":"paginated","sessionStartSource":"startup","threadSource":"app","environments":[],"dynamicTools":[],"selectedCapabilityRoots":[],"mockExperimentalField":null,"experimentalRawEvents":false}}"#,
                )
                .unwrap(),
        )
        .unwrap();

        assert_eq!(response["id"], "released-full");
        assert_eq!(response["result"]["model"], "gpt-5.6-sol");
        assert_eq!(response["result"]["serviceTier"], "priority");
        assert_eq!(response["result"]["reasoningEffort"], "high");
        assert_eq!(
            response["result"]["runtimeWorkspaceRoots"],
            serde_json::json!(["/workspace/project", "/workspace/shared"])
        );
        assert_eq!(
            response["result"]["activePermissionProfile"]["id"],
            ":workspace"
        );
        assert_eq!(response["result"]["multiAgentMode"], "explicitRequestOnly");
        assert_eq!(response["result"]["thread"]["mode"], "default");
        assert_eq!(response["result"]["thread"]["threadStartKind"], "default");
    }

    #[test]
    fn stable_thread_start_rejects_permissions_with_legacy_sandbox_atomically() {
        let mut core = CodexCore::default();
        let sequence = core.next_sequence;

        assert_eq!(
            core.request(
                br#"{"method":"thread/start","params":{"cwd":"/workspace/project","permissions":":workspace","sandbox":"workspace-write"}}"#,
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence);
        assert!(core.next_event().is_none());
    }

    #[test]
    fn stable_turn_start_inherits_released_thread_runtime_defaults() {
        let mut core = CodexCore::default();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/start","params":{"cwd":"/workspace/project","runtimeWorkspaceRoots":["/workspace/project","/workspace/shared"],"environments":[{"environmentId":"local","cwd":"/workspace/project"}],"dynamicTools":[{"name":"lookup","description":"Lookup data","inputSchema":{"type":"object"}}],"selectedCapabilityRoots":[{"id":"github@openai"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["thread"]["id"].as_str().unwrap().to_owned();
        while core.next_event().is_some() {}

        let turn: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "turn/start",
                        "params": {"threadId": &thread_id, "input": []},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let turn_id = turn["turn"]["id"].as_str().unwrap();
        let effective = core.session.stable_turn_start_params(turn_id).unwrap();
        assert_eq!(
            effective["runtimeWorkspaceRoots"],
            serde_json::json!(["/workspace/project", "/workspace/shared"])
        );
        assert_eq!(
            effective["environments"],
            serde_json::json!([{"environmentId":"local","cwd":"/workspace/project"}])
        );
        assert_eq!(
            effective["dynamicTools"],
            serde_json::json!([{
                "name":"lookup",
                "description":"Lookup data",
                "inputSchema":{"type":"object"}
            }])
        );
        assert_eq!(
            effective["selectedCapabilityRoots"],
            serde_json::json!([{"id":"github@openai"}])
        );
    }

    #[test]
    fn released_ipad_turn_start_accepts_null_overrides_and_complete_runtime_settings() {
        let mut core = CodexCore::default();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/start","params":{"cwd":"/workspace/project","model":"gpt-5.6-sol","modelProvider":"openai","config":{"model_reasoning_effort":"low"},"approvalPolicy":"on-request","approvalsReviewer":"user","permissions":":workspace","personality":"friendly","developerInstructions":"Desktop instructions"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["thread"]["id"].as_str().unwrap().to_owned();
        while core.next_event().is_some() {}

        let params = serde_json::json!({
                "threadId": thread_id,
                "clientUserMessageId": "01a00bbf-78aa-7a93-9988-3105bacf0999",
                "input": [{
                    "type": "text",
                    "text": "Reply with exactly CODEXPAD_REAL_PROVIDER_OK",
                    "text_elements": [],
                }],
                "cwd": "/workspace/project",
                "approvalPolicy": "on-request",
                "approvalsReviewer": "user",
                "sandboxPolicy": {
                    "type": "workspaceWrite",
                    "writableRoots": [],
                    "networkAccess": false,
                    "excludeTmpdirEnvVar": false,
                    "excludeSlashTmp": false,
                },
                "model": null,
                "serviceTier": null,
                "effort": null,
                "summary": "none",
                "collaborationMode": {
                    "mode": "default",
                    "settings": {
                        "model": "gpt-5.6-sol",
                        "reasoning_effort": "low",
                        "developer_instructions": "Desktop instructions",
                    },
                },
                "multiAgentMode": "explicitRequestOnly",
                "personality": "friendly",
                "outputSchema": null,
                "permissions": null,
                "responsesapiClientMetadata": {
                    "originator": "codex_desktop_rs",
                },
                "runtimeWorkspaceRoots": null,
        });
        let request = serde_json::to_vec(&serde_json::json!({
            "id": "ipad-real-turn",
            "method": "turn/start",
            "params": params,
        }))
        .unwrap();

        let response = core.request(&request).unwrap();
        let response: serde_json::Value = serde_json::from_slice(&response).unwrap();
        assert_eq!(response["id"], "ipad-real-turn");
        assert_eq!(response["result"]["turn"]["status"], "inProgress");
        let turn_id = response["result"]["turn"]["id"].as_str().unwrap();
        let effective = core.session.stable_turn_start_params(turn_id).unwrap();
        assert!(effective.get("runtimeWorkspaceRoots").is_none());
    }

    #[test]
    fn stable_turn_start_runtime_overrides_persist_for_subsequent_turns_after_sqlite_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut first = CodexCore::default();
        first.submit(open.as_bytes()).unwrap();

        let started: serde_json::Value = serde_json::from_slice(
            &first
                .request(
                    br#"{"method":"thread/start","params":{"cwd":"/workspace/project","runtimeWorkspaceRoots":["/workspace/project"],"environments":[{"environmentId":"initial","cwd":"/workspace/project"}],"dynamicTools":[{"type":"function","name":"initial_lookup","description":"Initial lookup","inputSchema":{"type":"object"}}],"selectedCapabilityRoots":[{"id":"initial@openai"}]}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["thread"]["id"].as_str().unwrap().to_owned();
        while first.next_event().is_some() {}

        let override_turn: serde_json::Value = serde_json::from_slice(
            &first
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "turn/start",
                        "params": {
                            "threadId": &thread_id,
                            "input": [],
                            "runtimeWorkspaceRoots": ["/workspace/override", "/workspace/shared"],
                            "environments": [{"environmentId":"override","cwd":"/workspace/override"}],
                            "dynamicTools": [{
                                "type": "function",
                                "name": "lookup_ticket",
                                "description": "Look up a ticket",
                                "inputSchema": {"type": "object"}
                            }],
                            "selectedCapabilityRoots": [{"id":"github@openai"}],
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let override_turn_id = override_turn["turn"]["id"].as_str().unwrap();
        let override_params = first
            .session
            .stable_turn_start_params(override_turn_id)
            .unwrap();
        assert_eq!(
            override_params["runtimeWorkspaceRoots"],
            serde_json::json!(["/workspace/override", "/workspace/shared"])
        );
        assert_eq!(
            override_params["environments"],
            serde_json::json!([{"environmentId":"override","cwd":"/workspace/override"}])
        );
        assert_eq!(
            override_params["dynamicTools"],
            serde_json::json!([{
                "type":"function",
                "name":"lookup_ticket",
                "description":"Look up a ticket",
                "inputSchema":{"type":"object"}
            }])
        );
        assert_eq!(
            override_params["selectedCapabilityRoots"],
            serde_json::json!([{"id":"github@openai"}])
        );
        while first.next_event().is_some() {}
        drop(first);

        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        while reopened.next_event().is_some() {}

        let resumed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/resume",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            resumed["runtimeWorkspaceRoots"],
            serde_json::json!(["/workspace/override", "/workspace/shared"])
        );
        assert_eq!(
            resumed["dynamicTools"],
            serde_json::json!([{
                "type":"function",
                "name":"lookup_ticket",
                "description":"Look up a ticket",
                "inputSchema":{"type":"object"}
            }])
        );
        assert_eq!(
            resumed["selectedCapabilityRoots"],
            serde_json::json!([{"id":"github@openai"}])
        );

        let inherited_turn: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "turn/start",
                        "params": {"threadId": &thread_id, "input": []},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let inherited_turn_id = inherited_turn["turn"]["id"].as_str().unwrap();
        let inherited_params = reopened
            .session
            .stable_turn_start_params(inherited_turn_id)
            .unwrap();
        assert_eq!(
            inherited_params["runtimeWorkspaceRoots"],
            serde_json::json!(["/workspace/override", "/workspace/shared"])
        );
        assert_eq!(
            inherited_params["environments"],
            serde_json::json!([{"environmentId":"override","cwd":"/workspace/override"}])
        );
    }

    #[test]
    fn stable_thread_start_creates_or_reuses_workspace_and_replays_from_storage() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();

        let first: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start-1","method":"thread/start","params":{"model":"gpt-5.6-sol","modelProvider":"openai","serviceTier":null,"cwd":"/workspace/new-project","approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":"workspace-write","config":{"model_reasoning_effort":"high"},"personality":"pragmatic","ephemeral":true,"sessionStartSource":"startup","threadSource":"app"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let first_id = first["result"]["thread"]["id"].as_str().unwrap().to_owned();
        assert_eq!(first["id"], "start-1");
        assert_eq!(first["result"]["thread"]["sessionId"], first_id);
        assert!(first["result"]["thread"]["name"].is_null());
        assert_eq!(first["result"]["thread"]["ephemeral"], true);
        assert_eq!(first["result"]["thread"]["threadSource"], "app");
        assert_eq!(first["result"]["model"], "gpt-5.6-sol");
        assert_eq!(first["result"]["modelProvider"], "openai");
        assert!(first["result"]["serviceTier"].is_null());
        assert_eq!(first["result"]["cwd"], "/workspace/new-project");
        assert_eq!(first["result"]["approvalPolicy"], "on-request");
        assert_eq!(first["result"]["approvalsReviewer"], "user");
        assert_eq!(first["result"]["sandbox"]["type"], "workspaceWrite");
        assert_eq!(first["result"]["reasoningEffort"], "high");
        let first_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(
            first_events
                .iter()
                .filter(|event| event["kind"] == "workspaceUpserted")
                .count(),
            1
        );
        assert_eq!(
            first_events
                .iter()
                .filter(|event| event["kind"] == "threadSettingsUpdated")
                .count(),
            1
        );
        let started = first_events
            .iter()
            .find(|event| event["method"] == "thread/started")
            .expect("thread/start must emit the official thread/started notification");
        assert_eq!(started["params"]["thread"], first["result"]["thread"]);

        let second: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/start","params":{"cwd":"/workspace/new-project","modelProvider":"openai","approvalPolicy":"never","approvalsReviewer":"auto_review","sandbox":"read-only"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let second_id = second["thread"]["id"].as_str().unwrap().to_owned();
        assert_ne!(first_id, second_id);
        assert_eq!(second["model"], "gpt-5.6-sol");
        assert_eq!(second["reasoningEffort"], "low");
        let second_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert!(
            second_events
                .iter()
                .all(|event| event["kind"] != "workspaceUpserted")
        );

        let sequence = core.next_sequence;
        assert_eq!(
            core.request(
                br#"{"method":"thread/start","params":{"cwd":"relative","modelProvider":"openai"}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
        assert_eq!(core.next_sequence, sequence);

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        for thread_id in [first_id, second_id] {
            let resumed: serde_json::Value = serde_json::from_slice(
                &reopened
                    .request(
                        serde_json::to_string(&serde_json::json!({
                            "method": "thread/resume",
                            "params": {"threadId": thread_id},
                        }))
                        .unwrap()
                        .as_bytes(),
                    )
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(resumed["thread"]["id"], thread_id);
            assert_eq!(resumed["cwd"], "/workspace/new-project");
        }
    }

    #[test]
    fn chatgpt_thread_start_remains_visible_to_the_interactive_cold_start_list() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();

        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start","method":"thread/start","params":{"cwd":"/workspace/chatgpt","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_eq!(
            started["result"]["thread"]["source"],
            serde_json::json!({"custom": "chatgpt"})
        );
        assert_eq!(started["result"]["thread"]["ephemeral"], false);

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let listed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(br#"{"method":"thread/list","params":{"sourceKinds":[]}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(listed["data"].as_array().unwrap().len(), 1);
        assert_eq!(listed["data"][0]["id"], thread_id);
        assert_eq!(
            listed["data"][0]["source"],
            serde_json::json!({"custom": "chatgpt"})
        );
    }

    #[test]
    fn thread_memory_mode_set_is_strict_persisted_and_not_an_app_server_notification() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let thread_id = "00000000-0000-0000-0000-000000000002";

        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        seed_thread_directory(&mut core);
        assert_eq!(
            core.session.thread_memory_mode(thread_id),
            Some(session::ThreadMemoryModeWire::Enabled)
        );

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"memory-mode","method":"thread/memoryMode/set","params":{"threadId":"00000000-0000-0000-0000-000000000002","mode":"disabled"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            response,
            serde_json::json!({"id": "memory-mode", "result": {}})
        );
        assert_eq!(
            core.session.thread_memory_mode(thread_id),
            Some(session::ThreadMemoryModeWire::Disabled)
        );
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadMemoryModeUpdated");
        assert_eq!(event["threadId"], thread_id);
        assert_eq!(event["mode"], "disabled");
        assert!(event.get("method").is_none());
        assert!(core.next_event().is_none());

        let sequence_after_success = core.next_sequence;
        let batch_count_after_success: i64 = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
            .unwrap();
        for invalid in [
            br#"{"method":"thread/memoryMode/set","params":{"threadId":"00000000-0000-0000-0000-000000000002"}}"#.as_slice(),
            br#"{"method":"thread/memoryMode/set","params":{"threadId":"00000000-0000-0000-0000-000000000002","mode":"polluted"}}"#.as_slice(),
            br#"{"method":"thread/memoryMode/set","params":{"threadId":"00000000-0000-0000-0000-000000000002","mode":"enabled","extra":true}}"#.as_slice(),
            br#"{"method":"thread/memoryMode/set","params":{"threadId":"","mode":"enabled"}}"#.as_slice(),
            br#"{"method":"thread/memoryMode/set","params":{"threadId":2,"mode":"enabled"}}"#.as_slice(),
            br#"{"method":"thread/memoryMode/set","params":{"threadId":"00000000-0000-0000-0000-000000000099","mode":"enabled"}}"#.as_slice(),
        ] {
            assert_eq!(core.request(invalid), Err(CoreError::InvalidArgument));
            assert_eq!(core.next_sequence, sequence_after_success);
            assert!(core.next_event().is_none());
            assert_eq!(
                core.session.thread_memory_mode(thread_id),
                Some(session::ThreadMemoryModeWire::Disabled)
            );
        }
        let batch_count_after_rejections: i64 = rusqlite::Connection::open(&database)
            .unwrap()
            .query_row("SELECT COUNT(*) FROM event_batches", [], |row| row.get(0))
            .unwrap();
        assert_eq!(batch_count_after_rejections, batch_count_after_success);

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        assert_eq!(
            reopened.session.thread_memory_mode(thread_id),
            Some(session::ThreadMemoryModeWire::Disabled)
        );
        assert!(
            std::iter::from_fn(|| reopened.next_event())
                .map(|event| serde_json::from_slice::<serde_json::Value>(&event).unwrap())
                .any(|event| {
                    event["kind"] == "threadMemoryModeUpdated"
                        && event["threadId"] == thread_id
                        && event["mode"] == "disabled"
                })
        );
    }

    fn storage_open_command(database: &std::path::Path, snapshots: &std::path::Path) -> String {
        format!(
            r#"{{"kind":"storage.open","databasePath":{},"snapshotDirectory":{}}}"#,
            serde_json::to_string(database.to_str().unwrap()).unwrap(),
            serde_json::to_string(snapshots.to_str().unwrap()).unwrap()
        )
    }

    fn seed_thread_directory(core: &mut CodexCore) {
        for command in [
            br#"{"kind":"workspace.open","workspace":{"id":"00000000-0000-0000-0000-000000000001","displayName":"Mars","rootBookmarkId":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000002","workspaceId":"00000000-0000-0000-0000-000000000001","title":"First task"},"metadata":{"sessionId":"session-tree","preview":"First task preview","ephemeral":false,"modelProvider":"openai","createdAt":100,"updatedAt":110,"recencyAt":110,"path":null,"cwd":"/workspace/first","cliVersion":"0.146.0-alpha.3.1","source":"vscode","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000003","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Second task"},"metadata":{"sessionId":"session-tree","preview":"Second task preview","ephemeral":false,"modelProvider":"openai","createdAt":200,"updatedAt":210,"recencyAt":210,"path":null,"cwd":"/workspace/second","cliVersion":"0.146.0-alpha.3.1","source":"vscode","threadSource":"user","parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":{"sha":"abc","branch":"main","originUrl":null}}}"#.as_slice(),
            br#"{"kind":"thread.start","thread":{"id":"00000000-0000-0000-0000-000000000004","workspaceId":"00000000-0000-0000-0000-000000000001","title":"Third task"},"metadata":{"sessionId":"00000000-0000-0000-0000-000000000004","preview":"Third task preview","ephemeral":false,"modelProvider":"other-provider","createdAt":300,"updatedAt":310,"recencyAt":310,"path":null,"cwd":"/workspace/third","cliVersion":"0.146.0-alpha.3.1","source":"exec","threadSource":null,"parentThreadId":null,"agentNickname":null,"agentRole":null,"gitInfo":null}}"#.as_slice(),
            br#"{"kind":"thread.archive","threadId":"00000000-0000-0000-0000-000000000004"}"#.as_slice(),
        ] {
            core.submit(command).unwrap();
        }
        while core.next_event().is_some() {}
    }

    fn official_core_with_running_turn() -> CodexCore {
        let mut core = CodexCore::default();
        seed_thread_directory(&mut core);
        core.submit(
            br#"{"kind":"turn.start","turn":{"id":"00000000-0000-0000-0000-000000000005","threadId":"00000000-0000-0000-0000-000000000002","status":"running"},"userItem":{"id":"00000000-0000-0000-0000-000000000006","threadId":"00000000-0000-0000-0000-000000000002","turnId":"00000000-0000-0000-0000-000000000005","kind":"userMessage","text":"Inspect the official thread"},"timestamp":120}"#,
        )
        .unwrap();
        while core.next_event().is_some() {}
        core
    }

    #[test]
    fn stable_compaction_replaces_prior_history_and_replays_from_storage() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        let started_thread: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"thread-1","method":"thread/start","params":{"cwd":"/workspace/compact","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started_thread["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        while core.next_event().is_some() {}

        let started_turn: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "turn/start",
                        "params": {
                            "threadId": &thread_id,
                            "input": [{"type": "text", "text": "retain this user fact"}],
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let first_turn_id = started_turn["turn"]["id"].as_str().unwrap();
        while core.next_event().is_some() {}
        core.submit(
            serde_json::to_string(&serde_json::json!({
                "kind": "turn.raw-history.commit",
                "threadId": &thread_id,
                "turnId": first_turn_id,
                "expectedNextOrder": 0,
                "entries": [{
                    "order": 0,
                    "source": "provider",
                    "itemJson": "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"old answer\"}]}",
                }],
                "completion": {
                    "responseId": "response-before-compact",
                    "endTurn": true,
                },
            }))
            .unwrap()
            .as_bytes(),
        )
        .unwrap();
        while core.next_event().is_some() {}

        let compact_response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "compact-1",
                        "method": "thread/compact/start",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            compact_response,
            serde_json::json!({
                "id": "compact-1",
                "result": {},
            })
        );
        let compact_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(
            compact_events[..3]
                .iter()
                .map(|event| event["kind"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["turnStarted", "itemAppended", "stableCompactStarted"]
        );
        assert_eq!(
            compact_events[3],
            serde_json::json!({
                "method": "thread/status/changed",
                "params": {
                    "threadId": &thread_id,
                    "status": {"type": "active", "activeFlags": []},
                },
            })
        );
        let compact_turn_id = compact_events[2]["turnId"].as_str().unwrap();
        let compact_item_id = compact_events[2]["itemId"].as_str().unwrap();
        assert_eq!(compact_events[1]["item"]["kind"], "contextCompaction");
        assert_eq!(compact_events[1]["item"]["text"], "");

        let replacement = "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"checkpoint summary\"}]}";
        core.submit(
            serde_json::to_string(&serde_json::json!({
                "kind": "turn.compact-history.commit",
                "threadId": &thread_id,
                "turnId": compact_turn_id,
                "itemId": compact_item_id,
                "replacementItems": [replacement],
                "responseId": "response-compact",
                "usage": {"inputTokens": 20, "outputTokens": 4},
            }))
            .unwrap()
            .as_bytes(),
        )
        .unwrap();
        let committed: serde_json::Value =
            serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(committed["kind"], "turnCompactionCommitted");
        let idle: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(
            idle,
            serde_json::json!({
                "method": "thread/status/changed",
                "params": {
                    "threadId": &thread_id,
                    "status": {"type": "idle"},
                },
            })
        );

        let prior: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(prior["items"], serde_json::json!([replacement]));
        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/read",
                        "params": {
                            "threadId": &thread_id,
                            "includeTurns": true,
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            read["thread"]["turns"][1]["items"][0]["type"],
            "contextCompaction"
        );
        assert_eq!(read["thread"]["turns"][1]["status"], "completed");

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed_prior: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(replayed_prior["items"], serde_json::json!([replacement]));
    }

    #[test]
    fn thread_inject_items_is_model_visible_hidden_and_durable() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start","method":"thread/start","params":{"cwd":"/workspace/injected","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        while core.next_event().is_some() {}

        let injected_item = serde_json::json!({
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": "side conversation context"}],
        });
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "inject",
                        "method": "thread/inject_items",
                        "params": {
                            "threadId": &thread_id,
                            "items": [&injected_item],
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id": "inject", "result": {}}));
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadItemsInjected");
        assert_eq!(event["afterTurnId"], serde_json::Value::Null);

        let prior: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(prior["items"][0].as_str().unwrap()).unwrap(),
            injected_item
        );

        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/read",
                        "params": {"threadId": &thread_id, "includeTurns": true},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"], serde_json::json!([]));

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(replayed["items"], prior["items"]);
    }

    #[test]
    fn thread_approve_guardian_denied_action_injects_exact_developer_approval() {
        let mut core = CodexCore::default();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start","method":"thread/start","params":{"cwd":"/workspace/guardian","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        while core.next_event().is_some() {}

        let denied_event = serde_json::json!({
            "id": "review-command-1",
            "target_item_id": "command-1",
            "turn_id": "turn-1",
            "started_at_ms": 100,
            "completed_at_ms": 200,
            "status": "denied",
            "risk_level": "high",
            "user_authorization": "low",
            "rationale": "review denied",
            "decision_source": "agent",
            "action": {
                "type": "command",
                "source": "shell",
                "command": "printf approved",
                "cwd": "/workspace/guardian"
            }
        });
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "approve",
                        "method": "thread/approveGuardianDeniedAction",
                        "params": {
                            "threadId": &thread_id,
                            "event": &denied_event,
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id": "approve", "result": {}}));
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "threadItemsInjected");
        let injected: serde_json::Value =
            serde_json::from_str(event["items"][0].as_str().unwrap()).unwrap();
        assert_eq!(injected["type"], "message");
        assert_eq!(injected["role"], "developer");
        let text = injected["content"][0]["text"].as_str().unwrap();
        assert!(text.starts_with(
            "The user has manually approved a specific action that was previously `Rejected`."
        ));
        assert!(text.contains(
            "Treat this as approval to perform that exact action in the same context in which it was originally requested."
        ));
        assert!(text.contains("\"outcome\": \"allowed\""));
        assert!(text.contains("\"command\": \"printf approved\""));

        let non_denied = serde_json::json!({
            "id": "review-command-2",
            "status": "approved",
            "action": {
                "type": "command",
                "source": "shell",
                "command": "printf ignored",
                "cwd": "/workspace/guardian"
            }
        });
        let ignored: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "ignored",
                        "method": "thread/approveGuardianDeniedAction",
                        "params": {
                            "threadId": &thread_id,
                            "event": non_denied,
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(ignored, serde_json::json!({"id": "ignored", "result": {}}));
        assert!(core.next_event().is_none());

        for invalid in [
            serde_json::json!({
                "method": "thread/approveGuardianDeniedAction",
                "params": {"threadId": &thread_id, "event": {"status": "denied"}}
            }),
            serde_json::json!({
                "method": "thread/approveGuardianDeniedAction",
                "params": {
                    "threadId": "",
                    "event": &denied_event
                }
            }),
        ] {
            assert_eq!(
                core.request(serde_json::to_string(&invalid).unwrap().as_bytes()),
                Err(CoreError::InvalidArgument)
            );
        }
    }

    #[test]
    fn thread_shell_command_runs_as_hidden_standalone_turn_and_persists_context() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("CodexPad.sqlite");
        let snapshots = directory.path().join("Snapshots");
        let open = storage_open_command(&database, &snapshots);
        let mut core = CodexCore::default();
        core.submit(open.as_bytes()).unwrap();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start","method":"thread/start","params":{"cwd":"/workspace/shell","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["result"]["thread"]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        while core.next_event().is_some() {}

        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "id": "shell",
                        "method": "thread/shellCommand",
                        "params": {
                            "threadId": &thread_id,
                            "command": "printf 'alpha' | tr a-z A-Z",
                        },
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id": "shell", "result": {}}));
        let started_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(
            started_events
                .iter()
                .map(|event| event["kind"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec!["turnStarted", "shellCommandStarted"]
        );
        assert_eq!(started_events[1]["cwd"], "/workspace/shell");
        assert_eq!(started_events[1]["standaloneTurn"], true);
        let command_id = started_events[1]["commandId"].as_str().unwrap();

        core.submit(
            serde_json::to_string(&serde_json::json!({
                "kind": "thread.shell-command.complete",
                "commandId": command_id,
                "exitCode": 0,
                "durationMillis": 1250,
                "stdout": "ALPHA",
                "stderr": "",
            }))
            .unwrap()
            .as_bytes(),
        )
        .unwrap();
        let completed_events: Vec<serde_json::Value> = std::iter::from_fn(|| core.next_event())
            .map(|event| serde_json::from_slice(&event).unwrap())
            .collect();
        assert_eq!(
            completed_events
                .iter()
                .map(|event| event["kind"].as_str().unwrap())
                .collect::<Vec<_>>(),
            vec![
                "threadItemsInjected",
                "turnStatusChanged",
                "shellCommandCompleted"
            ]
        );
        let prior: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        let contextual: serde_json::Value =
            serde_json::from_str(prior["items"][0].as_str().unwrap()).unwrap();
        let text = contextual["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("printf 'alpha' | tr a-z A-Z"));
        assert!(text.contains("Exit code: 0"));
        assert!(text.contains("Duration: 1.2500 seconds"));
        assert!(text.contains("ALPHA"));
        let read: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/read",
                        "params": {"threadId": &thread_id, "includeTurns": true},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(read["thread"]["turns"][0]["status"], "completed");
        assert_eq!(read["thread"]["turns"][0]["items"], serde_json::json!([]));

        drop(core);
        let mut reopened = CodexCore::default();
        reopened.submit(open.as_bytes()).unwrap();
        let replayed: serde_json::Value = serde_json::from_slice(
            &reopened
                .request(
                    serde_json::to_string(&serde_json::json!({
                        "method": "thread/prior-input-items",
                        "params": {"threadId": &thread_id},
                    }))
                    .unwrap()
                    .as_bytes(),
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(replayed["items"], prior["items"]);
    }

    #[test]
    fn thread_shell_command_joins_running_turn_and_validates_exact_params() {
        let mut core = official_core_with_running_turn();
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"shell","method":"thread/shellCommand","params":{"threadId":"00000000-0000-0000-0000-000000000002","command":"pwd"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response, serde_json::json!({"id": "shell", "result": {}}));
        let event: serde_json::Value = serde_json::from_slice(&core.next_event().unwrap()).unwrap();
        assert_eq!(event["kind"], "shellCommandStarted");
        assert_eq!(event["turnId"], "00000000-0000-0000-0000-000000000005");
        assert_eq!(event["standaloneTurn"], false);
        assert!(core.next_event().is_none());
        for invalid in [
            br#"{"method":"thread/shellCommand","params":{"threadId":"00000000-0000-0000-0000-000000000002","command":"  "}}"#.as_slice(),
            br#"{"method":"thread/shellCommand","params":{"threadId":"00000000-0000-0000-0000-000000000002","command":"pwd","extra":true}}"#.as_slice(),
        ] {
            assert_eq!(core.request(invalid), Err(CoreError::InvalidArgument));
        }
    }

    #[test]
    fn thread_unsubscribe_reports_official_statuses_and_updates_loaded_list() {
        let mut core = CodexCore::default();
        let started: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"id":"start","method":"thread/start","params":{"cwd":"/workspace","modelProvider":"openai"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        let thread_id = started["result"]["thread"]["id"].as_str().unwrap();

        let loaded: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"id":"loaded","method":"thread/loaded/list","params":{}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(loaded["result"]["data"], serde_json::json!([thread_id]));

        let unsubscribe = |core: &mut CodexCore, id: &str| {
            let request = serde_json::json!({
                "id": id,
                "method": "thread/unsubscribe",
                "params": {"threadId": thread_id},
            });
            serde_json::from_slice::<serde_json::Value>(
                &core.request(request.to_string().as_bytes()).unwrap(),
            )
            .unwrap()
        };
        assert_eq!(
            unsubscribe(&mut core, "first")["result"]["status"],
            "unsubscribed"
        );
        assert_eq!(
            unsubscribe(&mut core, "second")["result"]["status"],
            "notSubscribed"
        );
        let loaded: serde_json::Value = serde_json::from_slice(
            &core
                .request(br#"{"method":"thread/loaded/list","params":{}}"#)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(loaded["data"], serde_json::json!([]));

        let missing: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/unsubscribe","params":{"threadId":"00000000-0000-0000-0000-000000000099"}}"#,
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(missing["status"], "notLoaded");
        assert_eq!(
            core.request(
                br#"{"method":"thread/unsubscribe","params":{"threadId":"x","extra":true}}"#
            ),
            Err(CoreError::InvalidArgument)
        );
    }

    fn assert_official_turn_rejection_is_atomic(core: &mut CodexCore, sequence_before: u64) {
        assert_eq!(core.next_sequence, sequence_before);
        assert!(core.next_event().is_none());
        let response: serde_json::Value = serde_json::from_slice(
            &core
                .request(
                    br#"{"method":"thread/read","params":{"threadId":"00000000-0000-0000-0000-000000000002","includeTurns":true}}"#
                )
                .unwrap(),
        )
        .unwrap();
        assert_eq!(response["thread"]["status"]["type"], "active");
        assert_eq!(response["thread"]["turns"][0]["status"], "inProgress");
        assert_eq!(
            response["thread"]["turns"][0]["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}
